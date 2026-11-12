// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {CustomerLimits} from "../../contracts/core/CustomerLimits.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {Rates} from "../../contracts/core/Rates.sol";
import {Savings} from "../../contracts/core/Savings.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the savings vault against open question 29 in docs/plan.md and the pay savings interest
/// and close the day rows of docs/roles.md: closing a business day pays its interest at the savings rate
/// into the vault against equity, once per day, catching up every day missed, and a hold freezes the
/// current account first and the savings shares for the rest. The vault's own mechanics, the freezes,
/// forced transfers and share offset, are checked by the savings spike in test/compat/Savings.t.sol.
contract SavingsTest is BankFixture {
    /// @dev 73,000 at 1% a year earns 2.00 a day.
    uint256 constant SAVED = 73_000 * HKD;
    uint256 constant DAY_INTEREST = 2 * HKD;

    address scheduler;
    address support;

    function setUp() public override {
        super.setUp();
        scheduler = _staff("scheduler");
        support = _staff("support");
        _grantStaff(scheduler, Roles.SCHEDULER);
        _grantStaff(support, Roles.SUPPORT);
        // The days governance waited out at opening are closed, with nothing yet saved.
        _closeDay();
    }

    // Paying in and withdrawing

    function test_PayInAndWithdraw_MovesNoMoneyOnTheBooks() public {
        int256 deposits = ledger.balanceOf(GeneralLedger.Account.Deposits);
        uint256 shares = _payIn(alice, SAVED);
        assertEq(savings.totalAssets(), SAVED);
        assertEq(token.balanceOf(alice), 100_000 * HKD - SAVED);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Deposits), deposits, "savings are deposits");

        vm.prank(alice);
        savings.redeem(shares, alice, alice);
        assertEq(token.balanceOf(alice), 100_000 * HKD);
    }

    function test_PayIn_CountsAgainstNoDailyLimit() public {
        _govern(address(limits), abi.encodeCall(CustomerLimits.enrol, (alice)));
        uint256 app = limits.appAvailable(alice);
        uint256 unregistered = limits.unregisteredAvailable(alice);
        _payIn(alice, SAVED);
        vm.prank(alice);
        savings.withdraw(SAVED / 2, alice, alice);
        assertEq(limits.appAvailable(alice), app);
        assertEq(limits.unregisteredAvailable(alice), unregistered);
    }

    // Interest

    function test_Interest_PaidAsTheDayClosesAgainstEquity() public {
        uint256 shares = _payIn(alice, SAVED);
        int256 equity = ledger.balanceOf(GeneralLedger.Account.Equity);
        uint64 today = savings.lastPaidDay() + 1;
        vm.warp(block.timestamp + 1 days);

        vm.expectEmit(address(savings));
        emit Savings.InterestPaid(today, savings.interestRef(today), DAY_INTEREST, SAVINGS_RATE_BPS);
        _closeDay();

        assertEq(savings.totalAssets(), SAVED + DAY_INTEREST);
        assertEq(savings.previewRedeem(shares), SAVED + DAY_INTEREST - 1, "rounded down in the vault's favour");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Equity), equity + int256(DAY_INTEREST), "a cost to equity");
        _assertBooksBalance();
    }

    function test_Interest_OncePerDay() public {
        _payIn(alice, SAVED);
        vm.warp(block.timestamp + 1 days);
        _closeDay();
        uint256 assets = savings.totalAssets();
        uint256 entries = ledger.entryCount();

        vm.recordLogs();
        _closeDay();
        assertEq(vm.getRecordedLogs().length, 0, "a second trigger does nothing");
        assertEq(savings.totalAssets(), assets);
        assertEq(ledger.entryCount(), entries);
    }

    function test_Interest_CatchesUpEachDayMissed() public {
        _payIn(alice, SAVED);
        uint64 from = savings.lastPaidDay();
        vm.warp(block.timestamp + 3 days);
        _closeDay();

        assertEq(savings.lastPaidDay(), from + 3);
        // 2.00 on 73,000.00, then 2.00 on 73,002.00 (2.0000548 rounded down), then again.
        assertEq(savings.totalAssets(), SAVED + 3 * DAY_INTEREST);
        _assertBooksBalance();
    }

    /// @dev A cent more a day once the interest paid has added 365.00 to the holdings, about half a year in.
    function test_Interest_Compounds() public {
        _payIn(alice, SAVED);
        vm.warp(block.timestamp + 365 days);
        _closeDay();

        uint256 expected = SAVED;
        for (uint256 day = 0; day < 365; ++day) expected += (expected * SAVINGS_RATE_BPS) / (10_000 * 365);
        assertEq(savings.totalAssets(), expected);
        assertGt(expected, SAVED + 365 * DAY_INTEREST, "more than simple interest");
        _assertBooksBalance();
    }

    function test_Interest_DayEndsAtMidnightHongKong() public {
        // Move to 23:59 Hong Kong time (15:59 UTC), close, then a minute later it is a new day.
        uint256 hkMidnight = ((block.timestamp + 8 hours) / 1 days + 1) * 1 days - 8 hours;
        vm.warp(hkMidnight - 1 minutes);
        _closeDay();
        uint64 day = savings.lastPaidDay();
        vm.warp(hkMidnight - 1 seconds);
        _closeDay();
        assertEq(savings.lastPaidDay(), day, "still the same day at 23:59:59");
        vm.warp(hkMidnight);
        _closeDay();
        assertEq(savings.lastPaidDay(), day + 1);
    }

    function test_Interest_NothingAtAZeroRateOrWithNothingSaved() public {
        vm.warp(block.timestamp + 1 days);
        uint256 entries = ledger.entryCount();
        _closeDay();
        assertEq(ledger.entryCount(), entries, "nothing saved, nothing posted");

        _payIn(alice, SAVED);
        address treasurer = _staff("treasurer");
        _grantStaff(treasurer, Roles.TREASURY);
        bytes32 paper = keccak256("no savings rate");
        vm.prank(treasurer);
        rates.proposeProductRates(Rates.ProductRates(0, LOAN_RATE_BPS), paper);
        _govern(address(rates), abi.encodeCall(Rates.applyProductRates, (paper)));
        entries = ledger.entryCount();
        _closeDay();
        assertEq(ledger.entryCount(), entries, "a zero rate posts nothing");
        assertEq(savings.totalAssets(), SAVED);
    }

    /// @dev No interest while the bank is paused, and the days it held up are paid once it resumes.
    function test_Interest_WaitsOutAPause() public {
        _payIn(alice, SAVED);
        uint64 from = savings.lastPaidDay();
        _pauseBank();
        vm.warp(block.timestamp + 1 days);
        vm.prank(scheduler);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        savings.payInterestDue();
        _resumeBank();
        _closeDay();
        assertGt(savings.lastPaidDay(), from + 1, "the day held up and the time lock's days");
        assertGe(savings.totalAssets(), SAVED + 2 * DAY_INTEREST);
    }

    function test_Pause_StopsSharesMovingEvenByForce() public {
        uint256 shares = _payIn(alice, SAVED);
        _pauseBank();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        savings.redeem(shares, alice, alice);
        address enforcer = makeAddr("enforcer");
        vm.prank(governance);
        manager.grantRole(Roles.ENFORCER, enforcer, 0);
        vm.prank(enforcer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        savings.forcedTransfer(alice, pending, shares);
    }

    function test_Interest_OnlyTheScheduler() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        savings.payInterestDue();
    }

    // Holds

    function test_Hold_OnTheCurrentAccountFirst() public {
        _payIn(alice, SAVED);
        uint256 current = token.balanceOf(alice);
        _hold(alice, current);
        assertEq(token.frozen(alice), current);
        assertEq(savings.getFrozenTokens(alice), 0);
    }

    function test_Hold_ReachesSharesForWhatTheCurrentAccountDoesNotCover() public {
        _payIn(alice, SAVED);
        uint256 current = token.balanceOf(alice);
        uint256 rest = 10_000 * HKD;
        _hold(alice, current + rest);

        assertEq(savings.getFrozenTokens(alice), savings.previewWithdraw(rest));
        assertGe(savings.previewRedeem(savings.getFrozenTokens(alice)), rest);
        assertLe(token.frozen(alice), current);
        assertGe(token.frozen(alice) + savings.previewRedeem(savings.getFrozenTokens(alice)), current + rest);

        // No interest has been paid, so a share is still worth what was paid in for it.
        assertEq(savings.maxWithdraw(alice), SAVED - rest, "the rest of savings stays free");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxWithdraw.selector, alice, SAVED - rest + 1, SAVED - rest));
        savings.withdraw(SAVED - rest + 1, alice, alice);
    }

    function test_Hold_BeyondSavingsFreezesMoneyStillToArrive() public {
        _payIn(alice, SAVED);
        uint256 hold = 200_000 * HKD;
        _hold(alice, hold);

        assertEq(savings.getFrozenTokens(alice), savings.balanceOf(alice), "every share");
        assertEq(token.frozen(alice), hold - savings.previewRedeem(savings.balanceOf(alice)));
        assertGt(token.frozen(alice), token.balanceOf(alice), "more than the current account holds");
    }

    function test_Hold_CoverGrowsWithInterest() public {
        _payIn(alice, SAVED);
        uint256 rest = 10_000 * HKD;
        _hold(alice, token.balanceOf(alice) + rest);
        uint256 frozen = savings.getFrozenTokens(alice);

        vm.warp(block.timestamp + 30 days);
        _closeDay();
        assertEq(savings.getFrozenTokens(alice), frozen);
        assertGt(savings.previewRedeem(frozen), rest);
    }

    function test_Lift_UnfreezesSharesAndCurrentAccount() public {
        _payIn(alice, SAVED);
        uint256 id = _hold(alice, 50_000 * HKD);
        assertGt(savings.getFrozenTokens(alice), 0);

        address compliance = _staff("compliance");
        _grantStaff(compliance, Roles.COMPLIANCE);
        vm.prank(compliance);
        holds.lift(id, Roles.COMPLIANCE);
        assertEq(savings.getFrozenTokens(alice), 0);
        assertEq(token.frozen(alice), 0);
    }

    function test_Hold_WithNoSavingsStaysOnTheCurrentAccount() public {
        uint256 hold = 150_000 * HKD;
        _hold(alice, hold);
        assertEq(token.frozen(alice), hold);
        assertEq(savings.getFrozenTokens(alice), 0);
    }

    function test_SetFrozenShares_OnlyByRegister() public {
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, support));
        savings.setFrozenTokens(alice, 1);
    }

    /// @dev Over any run of paying in, closing days, holds and withdrawing, the vault covers what its shares
    /// are worth, the frozen shares and current account together cover each hold, and the books balance.
    function testFuzz_VaultCoversSharesAndHoldsAreCovered(uint8[10] calldata ops, uint32[10] calldata amounts) public {
        for (uint256 i = 0; i < ops.length; ++i) {
            address who = ops[i] % 2 == 0 ? alice : bob;
            uint256 op = (ops[i] / 2) % 4;
            if (op == 0) {
                uint256 amount = bound(amounts[i], 0, token.available(who));
                if (amount > 0) _payIn(who, amount);
            } else if (op == 1) {
                vm.warp(block.timestamp + bound(amounts[i], 1, 10) * 1 days);
                _closeDay();
            } else if (op == 2) {
                _hold(who, bound(amounts[i], 1, 250_000 * HKD));
            } else {
                uint256 amount = bound(amounts[i], 0, savings.maxWithdraw(who));
                vm.prank(who);
                savings.withdraw(amount, who, who);
            }
            assertGe(token.balanceOf(address(savings)), savings.previewRedeem(savings.totalSupply()));
            _assertHoldsCovered(alice);
            _assertHoldsCovered(bob);
            _assertBooksBalance();
        }
    }

    // Helpers

    function _closeDay() private {
        vm.prank(scheduler);
        savings.payInterestDue();
    }

    function _payIn(address who, uint256 amount) private returns (uint256 shares) {
        vm.startPrank(who);
        token.approve(address(savings), amount);
        shares = savings.deposit(amount, who);
        vm.stopPrank();
    }

    function _hold(address who, uint256 amount) private returns (uint256) {
        vm.prank(support);
        return holds.place(who, amount, Roles.SUPPORT, "test hold");
    }

    /// @dev What is frozen covers the account's holds: the frozen shares at their value now and the
    /// current account's freeze, which may run ahead of its balance.
    function _assertHoldsCovered(address who) private view {
        uint256 shares = savings.getFrozenTokens(who);
        assertLe(shares, savings.balanceOf(who), "never more shares frozen than held");
        assertGe(token.frozen(who) + savings.previewRedeem(shares), holds.heldOf(who), "holds covered");
    }
}
