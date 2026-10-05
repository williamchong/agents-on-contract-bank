// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {SpikeDepositToken} from "../../contracts/spike/SpikeDepositToken.sol";
import {SpikeLedger, SpikeLedgerEvents} from "../../contracts/spike/SpikeLedger.sol";
import {SpikeLendingGuard} from "../../contracts/spike/SpikeLendingGuard.sol";

/// @dev Checks that the opening balance sheet takes the demo's financial stress scenarios to their
/// limits within a few actions, at the real Hong Kong minimums applied to the simplified ratios,
/// while daily operation stays clear of them. See open question 9 in docs/plan.md.
contract RatiosTest is Test {
    uint64 constant LEDGER = 1;
    uint64 constant BOOKKEEPER = 2;
    uint64 constant CREDIT = 3;
    uint64 constant GOVERNANCE = 4;
    uint256 constant BPS = 10_000;

    /// @dev Total capital 8% (Cap. 155L) and the category 2 liquidity ratio 25% (Cap. 155Q).
    uint256 constant CAPITAL_MINIMUM_BPS = 800;
    uint256 constant LIQUIDITY_MINIMUM_BPS = 2500;
    uint256 constant ALLOWANCE_BPS = 100;

    /// @dev How far clear of the minimums daily operation should stay, and its interest rates.
    uint256 constant DAILY_CAPITAL_FLOOR_BPS = 900;
    uint256 constant DAILY_LIQUIDITY_FLOOR_BPS = 3000;
    uint256 constant LOAN_RATE_BPS = 600;
    uint256 constant SAVINGS_RATE_BPS = 200;
    uint256 constant SAVINGS_SHARE_OF_DEPOSITS = 5;

    /// @dev The opening balance sheet, in Hong Kong dollars.
    int128 constant CAPITAL = 1_000_000;
    int128 constant LOANS = 9_300_000;
    int128 constant SETTLEMENT = 1_000_000;
    int128 constant CASH = 500_000;
    int128 constant SECURITIES = 2_500_000;
    int128 constant DEPOSITS = 12_300_000;

    uint256 constant LOAN = 500_000;
    uint256 constant SMALL_LOAN = 300_000;
    uint256 constant CUSTOMERS = 10;
    uint256 constant PAYMENT = 150_000;

    AccessManager manager;
    SpikeDepositToken token;
    SpikeLedgerEvents ledger;
    SpikeLendingGuard guard;

    address seed = makeAddr("seed");
    address borrower = makeAddr("borrower");
    address pending = makeAddr("pending");
    address governance = makeAddr("governance");
    address[] customers;

    function setUp() public {
        manager = new AccessManager(address(this));
        token = new SpikeDepositToken(address(manager));
        ledger = new SpikeLedgerEvents(address(manager), token);
        guard = new SpikeLendingGuard(address(manager), ledger, CAPITAL_MINIMUM_BPS, LIQUIDITY_MINIMUM_BPS, ALLOWANCE_BPS);

        _setRole(address(token), token.mint.selector, LEDGER);
        _setRole(address(token), token.burn.selector, LEDGER);
        _setRole(address(ledger), ledger.post.selector, BOOKKEEPER);
        _setRole(address(ledger), ledger.postWithMint.selector, BOOKKEEPER);
        _setRole(address(ledger), ledger.postWithBurn.selector, BOOKKEEPER);
        _setRole(address(guard), guard.drawdown.selector, CREDIT);
        _setRole(address(guard), guard.setMinimums.selector, GOVERNANCE);
        _setRole(address(guard), guard.setAllowanceRate.selector, GOVERNANCE);
        manager.grantRole(LEDGER, address(ledger), 0);
        manager.grantRole(BOOKKEEPER, address(this), 0);
        manager.grantRole(BOOKKEEPER, address(guard), 0);
        manager.grantRole(CREDIT, address(this), 0);
        manager.grantRole(GOVERNANCE, governance, 0);

        token.allowUser(seed);
        token.allowUser(borrower);
        token.allowUser(pending);
        for (uint256 i = 0; i < CUSTOMERS; ++i) {
            customers.push(makeAddr(string.concat("customer", vm.toString(i))));
            token.allowUser(customers[i]);
        }

        _seed();
    }

    // Opening balance sheet

    function test_Seed_OpeningRatios() public view {
        assertEq(guard.capitalRatioBps(), 985);
        assertEq(guard.liquidityRatioBps(), 3252);
        _assertBooksBalance();
    }

    // Lending stopped by the capital ratio

    function test_LendingStopped_FourthLoanRefusedNamingCapital() public {
        for (uint256 i = 0; i < 3; ++i) {
            guard.drawdown(borrower, LOAN, "loan");
            console.log("Capital, liquidity after loan:", guard.capitalRatioBps(), guard.liquidityRatioBps());
            assertGe(guard.liquidityRatioBps(), LIQUIDITY_MINIMUM_BPS);
        }

        uint256 supply = token.totalSupply();
        vm.expectRevert(
            abi.encodeWithSelector(SpikeLendingGuard.CapitalRatioBelowMinimum.selector, _capitalAfter(LOAN), CAPITAL_MINIMUM_BPS)
        );
        guard.drawdown(borrower, LOAN, "loan");
        console.log("Capital the fourth loan would leave:", _capitalAfter(LOAN));
        assertEq(token.totalSupply(), supply);

        guard.drawdown(borrower, SMALL_LOAN, "smaller loan");
        console.log("Capital, liquidity after smaller loan:", guard.capitalRatioBps(), guard.liquidityRatioBps());
        assertGe(guard.capitalRatioBps(), CAPITAL_MINIMUM_BPS);
        assertGe(guard.liquidityRatioBps(), LIQUIDITY_MINIMUM_BPS);
        _assertBooksBalance();
    }

    // Run on deposits

    /// @dev Follows the lending in tour beat 5. Payments wait in a pending account and are released
    /// only while the settlement account covers them, standing in for the payment queue.
    function test_Run_QueuesThenDrainsWhileSolvent() public {
        _lendToTheLimit();
        uint256 capital = guard.capitalRatioBps();

        for (uint256 i = 0; i < CUSTOMERS; ++i) {
            vm.prank(customers[i]);
            token.transfer(pending, PAYMENT);
        }
        uint256 released = _release(0);
        assertLt(released, CUSTOMERS);
        console.log("Paid, queued, liquidity:", released, CUSTOMERS - released, guard.liquidityRatioBps());

        assertLt(guard.liquidityRatioBps(), LIQUIDITY_MINIMUM_BPS);
        uint256 liquidity = guard.liquidityRatioBps();
        vm.expectRevert(
            abi.encodeWithSelector(SpikeLendingGuard.LiquidityRatioBelowMinimum.selector, liquidity, LIQUIDITY_MINIMUM_BPS)
        );
        guard.drawdown(borrower, 1, "loan during the run");

        int128 shortfall = int128(int256((CUSTOMERS - released) * PAYMENT));
        ledger.post(_entry(SpikeLedger.Account.Settlement, shortfall, SpikeLedger.Account.Securities, -shortfall), "sell securities");
        assertEq(guard.liquidityRatioBps(), liquidity);

        assertEq(_release(released), CUSTOMERS);
        assertEq(token.balanceOf(pending), 0);
        console.log("Liquidity after the run:", guard.liquidityRatioBps());
        assertEq(guard.capitalRatioBps(), capital);
        assertGt(-ledger.balanceOf(SpikeLedger.Account.Equity), 0);
        _assertBooksBalance();
    }

    // Daily operation

    /// @dev A loan is drawn, then thirty days of loan interest collected from the borrower and
    /// savings interest paid on a share of deposits leave both ratios clear of their minimums.
    function test_DailyOperation_StaysClearOfMinimums() public {
        guard.drawdown(borrower, LOAN, "loan");
        uint256 loanInterest = (uint256(int256(LOANS)) * LOAN_RATE_BPS) / BPS / 365;
        uint256 savingsInterest = (uint256(int256(DEPOSITS)) / SAVINGS_SHARE_OF_DEPOSITS) * SAVINGS_RATE_BPS / BPS / 365;

        for (uint256 day = 0; day < 30; ++day) {
            ledger.postWithBurn(borrower, loanInterest, _entry(SpikeLedger.Account.Equity, -int128(int256(loanInterest))), "loan interest");
            ledger.postWithMint(seed, savingsInterest, _entry(SpikeLedger.Account.Equity, int128(int256(savingsInterest))), "savings interest");
            assertGe(guard.capitalRatioBps(), DAILY_CAPITAL_FLOOR_BPS);
            assertGe(guard.liquidityRatioBps(), DAILY_LIQUIDITY_FLOOR_BPS);
        }
        _assertBooksBalance();
    }

    // Boundary

    /// @dev Without the allowance, a loan that brings net loans to exactly equity over the minimum
    /// lands on 8.00%. The opening figures make that an exact number of dollars.
    function test_Boundary_ExactMinimumPassesOneMoreRefused() public {
        vm.prank(governance);
        guard.setAllowanceRate(0);
        int256 equity = -ledger.balanceOf(SpikeLedger.Account.Equity);
        int256 netLoans = ledger.balanceOf(SpikeLedger.Account.Loans) + ledger.balanceOf(SpikeLedger.Account.Allowance);
        assertEq((equity * int256(BPS)) % int256(CAPITAL_MINIMUM_BPS), 0);
        uint256 toTheLimit = uint256((equity * int256(BPS)) / int256(CAPITAL_MINIMUM_BPS) - netLoans);

        guard.drawdown(borrower, toTheLimit, "loan to the limit");
        assertEq(guard.capitalRatioBps(), CAPITAL_MINIMUM_BPS);

        vm.expectRevert(
            abi.encodeWithSelector(SpikeLendingGuard.CapitalRatioBelowMinimum.selector, CAPITAL_MINIMUM_BPS - 1, CAPITAL_MINIMUM_BPS)
        );
        guard.drawdown(borrower, 1, "one more");
    }

    /// @dev Losses beyond equity leave the bank insolvent, and it cannot lend at all.
    function test_Insolvent_RefusesEveryLoan() public {
        ledger.post(_entry(SpikeLedger.Account.Equity, 2_000_000, SpikeLedger.Account.Allowance, -2_000_000), "losses");
        vm.expectRevert(abi.encodeWithSelector(SpikeLendingGuard.CapitalRatioBelowMinimum.selector, 0, CAPITAL_MINIMUM_BPS));
        guard.drawdown(borrower, 1, "loan");
    }

    function test_Governance_RatesCappedAtWhole() public {
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(SpikeLendingGuard.RateAboveWhole.selector, BPS + 1));
        guard.setMinimums(BPS + 1, LIQUIDITY_MINIMUM_BPS);
        vm.expectRevert(abi.encodeWithSelector(SpikeLendingGuard.RateAboveWhole.selector, BPS + 1));
        guard.setAllowanceRate(BPS + 1);
        vm.stopPrank();
    }

    function test_EmptyBank_RatiosUnbounded() public {
        SpikeLendingGuard empty = new SpikeLendingGuard(
            address(manager),
            new SpikeLedgerEvents(address(manager), new SpikeDepositToken(address(manager))),
            CAPITAL_MINIMUM_BPS,
            LIQUIDITY_MINIMUM_BPS,
            ALLOWANCE_BPS
        );
        assertEq(empty.capitalRatioBps(), type(uint256).max);
        assertEq(empty.liquidityRatioBps(), type(uint256).max);
    }

    /// @dev Up to well past what the opening capital can carry.
    function testFuzz_DrawdownHoldsBothMinimumsOrLeavesNoTrace(uint32 amount) public {
        uint256 loan = bound(amount, 1, uint256(int256(LOANS)) / 2);
        uint256 supply = token.totalSupply();
        int256 loans = ledger.balanceOf(SpikeLedger.Account.Loans);

        try guard.drawdown(borrower, loan, "loan") {
            assertGe(guard.capitalRatioBps(), CAPITAL_MINIMUM_BPS);
            assertGe(guard.liquidityRatioBps(), LIQUIDITY_MINIMUM_BPS);
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == SpikeLendingGuard.CapitalRatioBelowMinimum.selector ||
                    selector == SpikeLendingGuard.LiquidityRatioBelowMinimum.selector
            );
            assertEq(token.totalSupply(), supply);
            assertEq(ledger.balanceOf(SpikeLedger.Account.Loans), loans);
        }
        _assertBooksBalance();
    }

    function test_Roles_OnlyCreditDrawsAndOnlyGovernanceSetsRates() public {
        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, borrower));
        guard.drawdown(borrower, 1, "loan");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, borrower));
        guard.setMinimums(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, borrower));
        guard.setAllowanceRate(0);
        vm.stopPrank();
    }

    // Helpers

    function _setRole(address target, bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    function _entry(SpikeLedger.Account a, int128 x) private pure returns (SpikeLedger.Line[] memory lines) {
        lines = new SpikeLedger.Line[](1);
        lines[0] = SpikeLedger.Line(a, x);
    }

    function _entry(
        SpikeLedger.Account a,
        int128 x,
        SpikeLedger.Account b,
        int128 y
    ) private pure returns (SpikeLedger.Line[] memory lines) {
        lines = new SpikeLedger.Line[](2);
        lines[0] = SpikeLedger.Line(a, x);
        lines[1] = SpikeLedger.Line(b, y);
    }

    /// @dev Capital paid in as securities, deposits taken against the rest of the assets, and the
    /// performing allowance on the opening loans. The seed account holds the deposits and pays
    /// each run customer their balance.
    function _seed() private {
        ledger.post(_entry(SpikeLedger.Account.Securities, CAPITAL, SpikeLedger.Account.Equity, -CAPITAL), "capital");

        SpikeLedger.Line[] memory lines = new SpikeLedger.Line[](4);
        lines[0] = SpikeLedger.Line(SpikeLedger.Account.Settlement, SETTLEMENT);
        lines[1] = SpikeLedger.Line(SpikeLedger.Account.Cash, CASH);
        lines[2] = SpikeLedger.Line(SpikeLedger.Account.Securities, SECURITIES - CAPITAL);
        lines[3] = SpikeLedger.Line(SpikeLedger.Account.Loans, LOANS);
        ledger.postWithMint(seed, uint256(int256(DEPOSITS)), lines, "opening deposits");

        int128 allowance = (LOANS * int128(int256(ALLOWANCE_BPS))) / int128(int256(BPS));
        ledger.post(_entry(SpikeLedger.Account.Equity, allowance, SpikeLedger.Account.Allowance, -allowance), "opening allowance");

        for (uint256 i = 0; i < CUSTOMERS; ++i) {
            vm.prank(seed);
            token.transfer(customers[i], PAYMENT);
        }
    }

    function _lendToTheLimit() private {
        for (uint256 i = 0; i < 3; ++i) guard.drawdown(borrower, LOAN, "loan");
        guard.drawdown(borrower, SMALL_LOAN, "smaller loan");
    }

    /// @dev Releases queued payments in order from `from` while the settlement account covers the
    /// next one, and returns how many have been released in all.
    function _release(uint256 from) private returns (uint256 released) {
        released = from;
        while (released < CUSTOMERS && ledger.balanceOf(SpikeLedger.Account.Settlement) >= int256(PAYMENT)) {
            ledger.postWithBurn(pending, PAYMENT, _entry(SpikeLedger.Account.Settlement, -int128(int256(PAYMENT))), "payment out");
            ++released;
        }
    }

    /// @dev The capital ratio a drawdown of `amount` would leave, worked out the guard's way.
    function _capitalAfter(uint256 amount) private view returns (uint256) {
        int256 allowance = int256((amount * ALLOWANCE_BPS + BPS - 1) / BPS);
        int256 equity = -ledger.balanceOf(SpikeLedger.Account.Equity) - allowance;
        int256 netLoans = ledger.balanceOf(SpikeLedger.Account.Loans) +
            ledger.balanceOf(SpikeLedger.Account.Allowance) +
            int256(amount) -
            allowance;
        return (uint256(equity) * BPS) / uint256(netLoans);
    }

    function _assertBooksBalance() private view {
        int256 sum;
        for (uint8 a = 0; a <= uint8(type(SpikeLedger.Account).max); ++a) sum += ledger.balanceOf(SpikeLedger.Account(a));
        assertEq(sum, 0);
    }
}
