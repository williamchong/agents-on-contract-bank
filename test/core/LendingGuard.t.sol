// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Attestations} from "../../contracts/core/Attestations.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {LendingGuard} from "../../contracts/core/LendingGuard.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the lending guard against open question 25 in docs/plan.md and the lending stopped by
/// the capital ratio scenario in docs/scenarios.md: from the opening balance sheet, three loans of
/// 500,000 are drawn, a fourth is refused naming capital and the ratio it would have left, and a loan
/// of 300,000 still goes through, at the figures tour beat 5 gives. A refused drawdown leaves no trace,
/// and nothing is drawn while a figure the ratios rest on is not current.
contract LendingGuardTest is BankFixture {
    uint256 constant BPS = 10_000;
    uint256 constant LOAN = 500_000 * HKD;
    uint256 constant SMALL_LOAN = 300_000 * HKD;

    address borrower = makeAddr("borrower");

    function setUp() public override {
        super.setUp();
        vm.prank(governance);
        token.allowUser(borrower);
        _attestFigures();
    }

    // Tour beat 5

    function test_Opening_Ratios() public view {
        assertEq(guard.capitalRatioBps(), 985);
        assertEq(guard.liquidityRatioBps(), 3252);
    }

    function test_LendingStopped_TourBeatFive() public {
        uint256[3] memory capital = [uint256(929), 879, 834];
        uint256[3] memory liquidity = [uint256(3125), 3007, 2898];
        for (uint256 i = 0; i < 3; ++i) {
            _draw(LOAN);
            assertEq(guard.capitalRatioBps(), capital[i]);
            assertEq(guard.liquidityRatioBps(), liquidity[i]);
        }

        uint256 supply = token.totalSupply();
        int256 loansBefore = ledger.balanceOf(GeneralLedger.Account.Loans);
        uint256 entries = ledger.entryCount();
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.CapitalRatioBelowMinimum.selector, 792, CAPITAL_MINIMUM_BPS));
        _draw(LOAN);
        assertEq(token.totalSupply(), supply, "a refused drawdown creates no tokens");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Loans), loansBefore);
        assertEq(ledger.entryCount(), entries);

        _draw(SMALL_LOAN);
        assertEq(guard.capitalRatioBps(), 808);
        assertEq(guard.liquidityRatioBps(), 2836);
        _assertBooksBalance();
    }

    /// @dev One entry: the loan, the tokens it creates and its performing allowance against equity.
    function test_Drawdown_OneEntryWithItsAllowance() public {
        uint256 allowance = LOAN / 100;
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](4);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Loans, int128(int256(LOAN)));
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Equity, int128(int256(allowance)));
        lines[2] = GeneralLedger.Line(GeneralLedger.Account.Allowance, -int128(int256(allowance)));
        lines[3] = GeneralLedger.Line(GeneralLedger.Account.Deposits, -int128(int256(LOAN)));
        vm.expectEmit(address(ledger));
        emit GeneralLedger.EntryPosted(ledger.entryCount() + 1, "loan", address(guard), lines);
        vm.expectEmit(address(guard));
        emit LendingGuard.DrawnWithinRatios("loan", borrower, LOAN, allowance, 929, 3125);
        _draw(LOAN);
        assertEq(token.balanceOf(borrower), LOAN);
    }

    // The two ratios

    function test_Liquidity_RefusedNamingIt() public {
        _govern(address(guard), abi.encodeCall(LendingGuard.setMinimums, (CAPITAL_MINIMUM_BPS, 3200)));
        _attestFigures();
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.LiquidityRatioBelowMinimum.selector, 3125, 3200));
        _draw(LOAN);
    }

    function test_BothBreached_NamesCapital() public {
        _govern(address(guard), abi.encodeCall(LendingGuard.setMinimums, (990, 9000)));
        _attestFigures();
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.CapitalRatioBelowMinimum.selector, 929, 990));
        _draw(LOAN);
    }

    /// @dev With no allowance, lending exactly to the minimum passes and a cent more is refused.
    function test_Boundary_ExactMinimumPassesOneMoreRefused() public {
        _govern(address(guard), abi.encodeCall(LendingGuard.setAllowanceRate, (0)));
        _attestFigures();
        int256 equity = -ledger.balanceOf(GeneralLedger.Account.Equity);
        int256 netLoans = ledger.balanceOf(GeneralLedger.Account.Loans) + ledger.balanceOf(GeneralLedger.Account.Allowance);
        assertEq((equity * int256(BPS)) % int256(CAPITAL_MINIMUM_BPS), 0);
        uint256 toTheLimit = uint256((equity * int256(BPS)) / int256(CAPITAL_MINIMUM_BPS) - netLoans);
        // Liquidity would stop a loan this large first, so its minimum is set aside here.
        _govern(address(guard), abi.encodeCall(LendingGuard.setMinimums, (CAPITAL_MINIMUM_BPS, 0)));
        _attestFigures();

        _draw(toTheLimit);
        assertEq(guard.capitalRatioBps(), CAPITAL_MINIMUM_BPS);
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.CapitalRatioBelowMinimum.selector, CAPITAL_MINIMUM_BPS - 1, CAPITAL_MINIMUM_BPS));
        _draw(1);
    }

    /// @dev Losses beyond equity leave the bank insolvent, and it cannot lend at all.
    function test_Insolvent_RefusesEveryLoan() public {
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](2);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Equity, _hkd(1_000_000));
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Allowance, -_hkd(1_000_000));
        vm.prank(treasury);
        ledger.post(lines, "losses");
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.CapitalRatioBelowMinimum.selector, 0, CAPITAL_MINIMUM_BPS));
        _draw(1);
    }

    /// @dev Up to well past what the opening capital can carry.
    function testFuzz_DrawdownHoldsBothMinimumsOrLeavesNoTrace(uint32 amount) public {
        uint256 loan = bound(amount, 1, 4_000_000 * HKD);
        uint256 supply = token.totalSupply();
        int256 loansBefore = ledger.balanceOf(GeneralLedger.Account.Loans);

        try this.draw(loan) {
            assertGe(guard.capitalRatioBps(), CAPITAL_MINIMUM_BPS);
            assertGe(guard.liquidityRatioBps(), LIQUIDITY_MINIMUM_BPS);
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == LendingGuard.CapitalRatioBelowMinimum.selector || selector == LendingGuard.LiquidityRatioBelowMinimum.selector
            );
            assertEq(token.totalSupply(), supply);
            assertEq(ledger.balanceOf(GeneralLedger.Account.Loans), loansBefore);
        }
        _assertBooksBalance();
    }

    // Attested figures

    function test_Figures_StaleSettlementStopsLending() public {
        vm.warp(block.timestamp + STATEMENT_MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.FigureNotCurrent.selector, GeneralLedger.Account.Settlement));
        _draw(LOAN);
    }

    function test_Figures_UnmatchedSecuritiesStopsLending() public {
        // The custodian's next statement disagrees with the ledger.
        _moveSettlement(int256(1_000 * HKD));
        vm.warp(block.timestamp + 1 minutes);
        uint256 asOf = block.timestamp - 1;
        uint256 sequence = attestations.figure(GeneralLedger.Account.Securities).sequence + 1;
        _acceptStatement(GeneralLedger.Account.Securities, sequence, 2_500_000 * HKD, asOf);
        assertFalse(attestations.isCurrent(GeneralLedger.Account.Securities));

        vm.expectRevert(abi.encodeWithSelector(LendingGuard.FigureNotCurrent.selector, GeneralLedger.Account.Securities));
        _draw(LOAN);
    }

    // Roles

    function test_Roles_OnlyTheLenderDrawsAndOnlyGovernanceSetsRates() public {
        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, borrower));
        guard.drawdown(borrower, LOAN, "loan");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, borrower));
        guard.setMinimums(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, borrower));
        guard.setAllowanceRate(0);
        vm.stopPrank();
    }

    function test_Governance_RatesCappedAtWhole() public {
        vm.startPrank(governance);
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.RateAboveWhole.selector, BPS + 1));
        guard.setMinimums(BPS + 1, LIQUIDITY_MINIMUM_BPS);
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.RateAboveWhole.selector, BPS + 1));
        guard.setAllowanceRate(BPS + 1);
        vm.stopPrank();
    }

    /// @dev A drawdown as the loans module makes it, for the fuzz test to catch its refusal.
    function draw(uint256 amount) external {
        _draw(amount);
    }

    function _draw(uint256 amount) private {
        vm.prank(address(loans));
        guard.drawdown(borrower, amount, "loan");
    }

    function _acceptStatement(GeneralLedger.Account account, uint256 sequence, uint256 closing, uint256 asOf) private {
        Attestations.Statement memory m = Attestations.Statement(keccak256("semt.002"), sequence, closing, asOf, keccak256("document"));
        attestations.acceptStatement(account, m, _signP256(custodianKey, attestations.hashStatement(m)));
    }
}
