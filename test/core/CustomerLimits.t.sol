// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DailyLimit} from "../../contracts/core/DailyLimit.sol";
import {CustomerLimits} from "../../contracts/core/CustomerLimits.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the app channel's limits and the payee register against the limits in docs/roles.md and
/// open question 20 in docs/plan.md: every movement an enrolled customer starts counts against the app
/// limit, however it was started, payments to payees not registered count against the smaller
/// unregistered payee limit, a payee registered from a device waits out its waiting period, and a
/// customer can lower their own limits but not raise them.
contract CustomerLimitsTest is BankFixture {
    bytes32 constant TRANSFER_TYPEHASH =
        keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
    bytes32 constant SUPPLIER = keccak256("a supplier at another bank");

    address dave;
    uint256 daveKey;
    address spender = makeAddr("spender");

    function setUp() public override {
        super.setUp();
        (dave, daveKey) = makeAddrAndKey("dave");
        vm.startPrank(governance);
        token.allowUser(dave);
        token.allowUser(spender);
        limits.enrol(dave);
        vm.stopPrank();
        vm.prank(otherCustomers);
        token.transfer(dave, 100_000 * HKD);
        vm.startPrank(dave);
        token.approve(address(payments), type(uint256).max);
        // Bob is a payee Dave registered long ago, so transfers to him count against the app limit only.
        limits.registerPayee(limits.payeeOf(bob));
        vm.stopPrank();
        vm.warp(block.timestamp + PAYEE_WAIT);
    }

    // The app limit

    function test_App_TransfersCountAgainstTheDay() public {
        _transfer(6_000 * HKD);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 5_000 * HKD, 4_000 * HKD));
        _transfer(5_000 * HKD);
    }

    function test_App_AnAllowanceSpentCounts() public {
        vm.prank(dave);
        token.approve(spender, 50_000 * HKD);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 11_000 * HKD, APP_LIMIT));
        token.transferFrom(dave, bob, 11_000 * HKD);
    }

    function test_App_ASignedAuthorisationCounts() public {
        bytes memory sig = _sign(11_000 * HKD, 0);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 11_000 * HKD, APP_LIMIT));
        token.transferWithAuthorization(dave, bob, 11_000 * HKD, 0, block.timestamp + 1 hours, 0, sig);
    }

    function test_App_ForcedTransfersAreTheBanks() public {
        vm.prank(address(assisted));
        token.forcedTransfer(dave, bob, 50_000 * HKD);
        assertEq(limits.appAvailable(dave), APP_LIMIT);
    }

    function test_App_ModulesWithTheirOwnChannelAreNotCounted() public {
        vm.prank(dave);
        token.transfer(address(cash), 20_000 * HKD);
        assertEq(limits.appAvailable(dave), APP_LIMIT);
    }

    function test_App_CustomersNotEnrolledAreNotCounted() public {
        vm.prank(alice);
        token.transfer(bob, 50_000 * HKD);
        assertEq(limits.appAvailable(alice), APP_LIMIT);
    }

    function test_App_ResetsAtMidnightHongKongTime() public {
        // 23:59 in Hong Kong is 15:59 UTC.
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 15 hours + 59 minutes);
        _transfer(APP_LIMIT);
        assertEq(limits.appAvailable(dave), 0);
        vm.warp(block.timestamp + 1 minutes);
        assertEq(limits.appAvailable(dave), APP_LIMIT);
    }

    // Payees

    /// @dev A stolen phone cannot empty the account into another customer's either.
    function test_Payee_TransferToAnUnregisteredCustomerHasTheSmallerLimit() public {
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 3_000 * HKD, UNREGISTERED_PAYEE_LIMIT));
        token.transfer(alice, 3_000 * HKD);
    }

    function test_Payee_ReRegisteringKeepsItsTime() public {
        uint48 first = _register(SUPPLIER);
        vm.warp(block.timestamp + 1 hours);
        assertEq(_register(SUPPLIER), first);
    }

    function test_Payee_UnregisteredPaymentsHaveTheSmallerLimit() public {
        _pay(1_500 * HKD, SUPPLIER);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 1_000 * HKD, 500 * HKD));
        _pay(1_000 * HKD, SUPPLIER);
    }

    function test_Payee_RegisteredFromADeviceWaitsItsPeriod() public {
        vm.prank(dave);
        limits.registerPayee(SUPPLIER);
        assertFalse(limits.isPayee(dave, SUPPLIER));
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 3_000 * HKD, UNREGISTERED_PAYEE_LIMIT));
        _pay(3_000 * HKD, SUPPLIER);

        vm.warp(block.timestamp + PAYEE_WAIT);
        assertTrue(limits.isPayee(dave, SUPPLIER));
        _pay(3_000 * HKD, SUPPLIER);
        assertEq(limits.unregisteredAvailable(dave), UNREGISTERED_PAYEE_LIMIT, "a registered payee is not counted as unregistered");
    }

    function test_Payee_PaymentsCountAgainstTheAppLimitToo() public {
        vm.prank(dave);
        limits.registerPayee(SUPPLIER);
        vm.warp(block.timestamp + PAYEE_WAIT);
        _pay(8_000 * HKD, SUPPLIER);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 3_000 * HKD, 2_000 * HKD));
        _transfer(3_000 * HKD);
    }

    function test_Payee_RemovedAtOnce() public {
        vm.startPrank(dave);
        limits.registerPayee(SUPPLIER);
        vm.warp(block.timestamp + PAYEE_WAIT);
        limits.removePayee(SUPPLIER);
        vm.stopPrank();
        assertFalse(limits.isPayee(dave, SUPPLIER));
    }

    function test_Payee_RemovedWhileStillWaiting() public {
        vm.startPrank(dave);
        limits.registerPayee(SUPPLIER);
        limits.removePayee(SUPPLIER);
        vm.stopPrank();
        vm.warp(block.timestamp + PAYEE_WAIT);
        assertFalse(limits.isPayee(dave, SUPPLIER));
    }

    function test_Payee_OnlyAnEnrolledCustomerRegisters() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CustomerLimits.NotEnrolled.selector, alice));
        limits.registerPayee(SUPPLIER);
    }

    // A payment that comes back

    /// @dev The receiving bank rejects a payment: the money comes back, and so does the day's limit it used.
    function test_Rejected_PaymentGivesItsLimitsBack() public {
        bytes32 ref = _payAndSend(1_500 * HKD, SUPPLIER);
        assertEq(limits.unregisteredAvailable(dave), UNREGISTERED_PAYEE_LIMIT - 1_500 * HKD);
        _rejectPayment(ref, 1_500 * HKD);
        assertEq(limits.appAvailable(dave), APP_LIMIT);
        assertEq(limits.unregisteredAvailable(dave), UNREGISTERED_PAYEE_LIMIT);
    }

    function test_Rejected_ToARegisteredPayeeGivesBackTheAppLimitOnly() public {
        vm.prank(dave);
        limits.registerPayee(SUPPLIER);
        vm.warp(block.timestamp + PAYEE_WAIT);
        _transfer(1_000 * HKD);
        bytes32 ref = _payAndSend(3_000 * HKD, SUPPLIER);
        assertEq(limits.appAvailable(dave), APP_LIMIT - 4_000 * HKD);
        _rejectPayment(ref, 3_000 * HKD);
        assertEq(limits.appAvailable(dave), APP_LIMIT - 1_000 * HKD, "the transfer stays counted");
        assertEq(limits.unregisteredAvailable(dave), UNREGISTERED_PAYEE_LIMIT);
    }

    /// @dev A rejection that arrives the next day gives nothing back: that day's limits have already reset.
    function test_Rejected_NextDayGivesNothingBackToToday() public {
        bytes32 ref = _payAndSend(1_500 * HKD, SUPPLIER);
        vm.warp(block.timestamp + 1 days);
        _transfer(9_000 * HKD);
        _rejectPayment(ref, 1_500 * HKD);
        assertEq(limits.appAvailable(dave), APP_LIMIT - 9_000 * HKD);
    }

    /// @dev A payer enrolled only after paying had nothing counted, so the rejection gives nothing back and
    /// still goes through.
    function test_Rejected_PaymentOfAPayerEnrolledSincePays() public {
        address eve = makeAddr("eve");
        vm.prank(governance);
        token.allowUser(eve);
        vm.prank(otherCustomers);
        token.transfer(eve, 10_000 * HKD);
        vm.startPrank(eve);
        token.approve(address(payments), 3_000 * HKD);
        bytes32 ref = payments.pay(3_000 * HKD, SUPPLIER);
        vm.stopPrank();
        payments.release(10);
        vm.prank(governance);
        limits.enrol(eve);
        uint256 before = token.balanceOf(eve);
        _rejectPayment(ref, 3_000 * HKD);
        assertEq(token.balanceOf(eve), before + 3_000 * HKD);
        assertEq(limits.appAvailable(eve), APP_LIMIT);
    }

    // The customer's own limits

    function test_Own_LoweredAtOnce() public {
        vm.prank(dave);
        limits.lowerLimits(1_000 * HKD, 500 * HKD);
        assertEq(limits.appLimit(dave), 1_000 * HKD);
        assertEq(limits.unregisteredLimit(dave), 500 * HKD);
        vm.expectRevert(abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, _key(dave), 1_500 * HKD, 1_000 * HKD));
        _transfer(1_500 * HKD);
    }

    function test_Own_CannotBeRaisedFromADevice() public {
        vm.startPrank(dave);
        limits.lowerLimits(1_000 * HKD, 500 * HKD);
        vm.expectRevert(abi.encodeWithSelector(CustomerLimits.NotLower.selector, 2_000 * HKD, 1_000 * HKD));
        limits.lowerLimits(2_000 * HKD, 500 * HKD);
        vm.stopPrank();
    }

    function test_Own_ZeroRefused() public {
        vm.prank(dave);
        vm.expectRevert(CustomerLimits.ZeroLimit.selector);
        limits.lowerLimits(0, 500 * HKD);
    }

    function test_Own_UnregisteredNeverAboveTheApp() public {
        vm.prank(dave);
        limits.lowerLimits(1_000 * HKD, 1_500 * HKD);
        assertEq(limits.unregisteredLimit(dave), 1_000 * HKD);
    }

    function test_Own_TheBanksLowerLimitPrevails() public {
        vm.prank(dave);
        limits.lowerLimits(5_000 * HKD, 1_000 * HKD);
        vm.prank(governance);
        limits.setLimits(CustomerLimits.Limits(3_000 * HKD, UNREGISTERED_PAYEE_LIMIT, PAYEE_WAIT));
        assertEq(limits.appLimit(dave), 3_000 * HKD);
    }

    // Wiring

    function test_TheTokenAndPaymentsKeepTheCount() public view {
        assertTrue(_holds(Roles.LIMIT_KEEPER, address(token)));
        assertTrue(_holds(Roles.LIMIT_KEEPER, address(payments)));
        assertFalse(_holds(Roles.LIMIT_KEEPER, governance));
    }

    // Helpers

    function _transfer(uint256 amount) private {
        vm.prank(dave);
        token.transfer(bob, amount);
    }

    function _register(bytes32 payee) private returns (uint48) {
        vm.prank(dave);
        return limits.registerPayee(payee);
    }

    function _pay(uint256 amount, bytes32 payee) private {
        vm.prank(dave);
        payments.pay(amount, payee);
    }

    function _payAndSend(uint256 amount, bytes32 payee) private returns (bytes32 ref) {
        vm.prank(dave);
        ref = payments.pay(amount, payee);
        payments.release(10);
    }

    function _key(address customer) private pure returns (bytes32) {
        return bytes32(uint256(uint160(customer)));
    }

    function _sign(uint256 value, bytes32 nonce) private view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(TRANSFER_TYPEHASH, dave, bob, value, 0, block.timestamp + 1 hours, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(daveKey, MessageHashUtils.toTypedDataHash(_separator(address(token)), structHash));
        return abi.encodePacked(r, s, v);
    }
}
