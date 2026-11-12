// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Vm.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {StandingOrders} from "../../contracts/core/StandingOrders.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the standing orders module against open question 30 in docs/plan.md and the standing
/// order rows of docs/roles.md: an order is set up only to a payee on the customer's register and in
/// effect, with the allowance for its payments; the scheduler makes every monthly payment due, inside the
/// bank through the module or to another bank through payments; a payment the account cannot cover is
/// missed and not tried again; the customer may cancel at any time; and its payments count against
/// neither daily limit.
contract StandingOrdersTest is BankFixture {
    uint256 constant RENT = 1_000 * HKD;
    uint256 constant PAYMENTS = 12;
    bytes32 constant LANDLORD = keccak256("landlord at another bank");

    address scheduler;
    address support;

    function setUp() public override {
        super.setUp();
        scheduler = _staff("scheduler");
        support = _staff("support");
        _grantStaff(scheduler, Roles.SCHEDULER);
        _grantStaff(support, Roles.SUPPORT);
        vm.startPrank(governance);
        limits.enrol(alice);
        limits.enrol(bob);
        vm.stopPrank();
        vm.startPrank(alice);
        limits.registerPayee(limits.payeeOf(bob));
        limits.registerPayee(LANDLORD);
        vm.stopPrank();
        vm.warp(block.timestamp + PAYEE_WAIT);
    }

    // Setting up

    function test_SetUp_ToARegisteredPayee() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        StandingOrders.Order memory o = orders.order(ref);
        assertEq(o.payer, alice);
        assertEq(o.to, bob);
        assertEq(o.payee, limits.payeeOf(bob));
        assertEq(uint8(o.status), uint8(StandingOrders.Status.Active));
        assertEq(orders.committed(alice), RENT * PAYMENTS);
        assertEq(orders.paymentsDue(ref), 0, "the first falls due a month on");
    }

    function test_SetUp_RefusesAPayeeNotRegistered() public {
        address carol = makeAddr("carol");
        vm.prank(governance);
        limits.enrol(carol);
        vm.startPrank(alice);
        token.approve(address(orders), RENT * PAYMENTS);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.PayeeNotInEffect.selector, alice, limits.payeeOf(carol)));
        orders.setUp(carol, bytes32(0), RENT, PAYMENTS);
        vm.stopPrank();
    }

    /// @dev A stolen phone registers a payee and sets up an order at once: the payee is not yet in effect.
    function test_SetUp_RefusesAPayeeStillWaiting() public {
        bytes32 stranger = keccak256("stranger");
        vm.startPrank(alice);
        limits.registerPayee(stranger);
        token.approve(address(orders), RENT * PAYMENTS);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.PayeeNotInEffect.selector, alice, stranger));
        orders.setUp(address(0), stranger, RENT, PAYMENTS);
        vm.stopPrank();
    }

    function test_SetUp_RefusesAnAllowanceTooSmall() public {
        _setUp(bob, RENT, PAYMENTS);
        vm.startPrank(alice);
        token.approve(address(orders), RENT * PAYMENTS + RENT);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.MandateTooSmall.selector, RENT * PAYMENTS + RENT, RENT * PAYMENTS * 2));
        orders.setUp(address(0), LANDLORD, RENT, PAYMENTS);
        vm.stopPrank();
    }

    /// @dev A bank-owned account is no payee, even if the customer registered its address.
    function test_SetUp_RefusesABankOwnedAccount() public {
        vm.startPrank(alice);
        limits.registerPayee(limits.payeeOf(pending));
        vm.warp(block.timestamp + PAYEE_WAIT);
        token.approve(address(orders), RENT * PAYMENTS);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotACustomer.selector, pending));
        orders.setUp(pending, bytes32(0), RENT, PAYMENTS);
        vm.stopPrank();
    }

    function test_SetUp_RefusesZero() public {
        vm.startPrank(alice);
        vm.expectRevert(StandingOrders.ZeroAmount.selector);
        orders.setUp(bob, bytes32(0), 0, PAYMENTS);
        vm.expectRevert(StandingOrders.NoPayments.selector);
        orders.setUp(bob, bytes32(0), RENT, 0);
        vm.stopPrank();
    }

    // Paying

    function test_Pay_InsideTheBank() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        (uint256 aliceBefore, uint256 bobBefore) = (token.balanceOf(alice), token.balanceOf(bob));
        uint256 entries = ledger.entryCount();
        uint256 app = limits.appAvailable(alice);
        uint256 unregistered = limits.unregisteredAvailable(alice);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);

        vm.expectEmit(address(orders));
        emit StandingOrders.OrderPaid(ref, 1, RENT, bytes32(0));
        _payDue(ref);

        assertEq(token.balanceOf(alice), aliceBefore - RENT);
        assertEq(token.balanceOf(bob), bobBefore + RENT);
        assertEq(token.balanceOf(address(orders)), 0);
        assertEq(ledger.entryCount(), entries, "money between customers posts nothing");
        assertEq(limits.appAvailable(alice), app, "counts against no limit");
        assertEq(limits.unregisteredAvailable(alice), unregistered);
        assertEq(orders.order(ref).paid, 1);
        assertEq(orders.committed(alice), RENT * (PAYMENTS - 1));
    }

    function test_Pay_ToAnotherBankThroughPayments() public {
        bytes32 ref = _setUp(address(0), RENT, PAYMENTS);
        uint256 balance = token.balanceOf(alice);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        vm.recordLogs();
        _payDue(ref);

        assertEq(token.balanceOf(alice), balance - RENT);
        assertEq(token.balanceOf(address(payments)), RENT, "queued in payments");
        assertEq(token.balanceOf(address(orders)), 0);
        StandingOrders.Order memory o = orders.order(ref);
        assertEq(o.paid, 1);

        bytes32 paymentRef = _paymentRefPaid(ref);
        Payments.Payment memory p = payments.outgoing(paymentRef);
        assertEq(p.party, alice, "the customer is the payer");
        assertEq(p.amount, RENT);
        assertEq(uint8(p.status), uint8(Payments.Status.Queued));

        payments.release(1);
        _rejectPayment(paymentRef, RENT);
        assertEq(token.balanceOf(alice), balance, "a rejected payment comes back to the customer");
        _assertBooksBalance();
    }

    function test_Pay_LateTriggerPaysEachDateOnce() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        uint256 bobBefore = token.balanceOf(bob);
        vm.warp(block.timestamp + 3 * INSTALMENT_PERIOD);
        _payDue(ref);
        assertEq(token.balanceOf(bob), bobBefore + 3 * RENT);

        vm.recordLogs();
        _payDue(ref);
        assertEq(vm.getRecordedLogs().length, 0, "a second trigger does nothing");
        assertEq(orders.order(ref).tried, 3);
    }

    function test_Pay_MissedWhenTheAccountCannotCoverItAndNotRetried() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        _save(token.balanceOf(alice) - RENT / 2);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);

        vm.expectEmit(address(orders));
        emit StandingOrders.OrderMissed(ref, 1, RENT);
        _payDue(ref);
        assertEq(token.balanceOf(alice), RENT / 2);

        vm.prank(otherCustomers);
        token.transfer(alice, 10 * RENT);
        _payDue(ref);
        assertEq(orders.order(ref).tried, 1, "a missed payment is not tried again");

        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        _payDue(ref);
        StandingOrders.Order memory o = orders.order(ref);
        assertEq(o.tried, 2);
        assertEq(o.paid, 1, "the next is paid");
        assertEq(orders.committed(alice), RENT * (PAYMENTS - 2));
    }

    function test_Pay_MissedUnderAHold() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        uint256 balance = token.balanceOf(alice);
        vm.prank(support);
        holds.place(alice, balance, Roles.SUPPORT, "lost phone");
        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        _assertMissed(ref, balance);
    }

    /// @dev A payer blocked since setting up the order cannot pay a landlord at another bank either; nothing
    /// is left in the module or in payments.
    function test_Pay_ToAnotherBankMissedWhenBlocked() public {
        bytes32 ref = _setUp(address(0), RENT, PAYMENTS);
        uint256 balance = token.balanceOf(alice);
        address compliance = _staff("compliance");
        _grantStaff(compliance, Roles.COMPLIANCE);
        vm.prank(compliance);
        token.blockUser(alice);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        _assertMissed(ref, balance);
        assertEq(token.balanceOf(address(payments)), 0);
    }

    /// @dev A payee the bank has since blocked cannot be paid: the money taken for it goes back at once.
    function test_Pay_ThatCannotLandLeavesNothingBehind() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        uint256 balance = token.balanceOf(alice);
        address compliance = _staff("compliance");
        _grantStaff(compliance, Roles.COMPLIANCE);
        vm.prank(compliance);
        token.blockUser(bob);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);

        vm.expectEmit(address(orders));
        emit StandingOrders.OrderMissed(ref, 1, RENT);
        _payDue(ref);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(address(orders)), 0);
    }

    function test_Pay_MissedOnceTheAllowanceIsWithdrawn() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        vm.prank(alice);
        token.approve(address(orders), 0);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        _assertMissed(ref, token.balanceOf(alice));
    }

    function test_Pay_CompletesAfterTheLastPayment() public {
        bytes32 ref = _setUp(bob, RENT, 2);
        vm.warp(block.timestamp + 5 * INSTALMENT_PERIOD);
        vm.expectEmit(address(orders));
        emit StandingOrders.OrderCompleted(ref);
        _payDue(ref);
        assertEq(orders.order(ref).paid, 2, "never more than the order's payments");
        assertEq(orders.committed(alice), 0);

        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotActive.selector, ref, StandingOrders.Status.Completed));
        orders.payDue(ref);
    }

    function test_Pay_OnlyTheScheduler() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        orders.payDue(ref);
    }

    function test_Deliver_OnlyTheModuleItself() public {
        vm.prank(alice);
        vm.expectRevert(StandingOrders.OnlySelf.selector);
        orders.deliver(alice, bob, bytes32(0), RENT);
    }

    // Cancelling

    function test_Cancel_StopsEveryPaymentAfter() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        _payDue(ref);
        vm.prank(alice);
        orders.cancel(ref);
        assertEq(orders.committed(alice), 0);

        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotActive.selector, ref, StandingOrders.Status.Cancelled));
        orders.payDue(ref);
    }

    function test_Cancel_RefusesAnOrderNoLongerActive() public {
        bytes32 ref = _setUp(bob, RENT, 1);
        vm.warp(block.timestamp + INSTALMENT_PERIOD);
        _payDue(ref);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotActive.selector, ref, StandingOrders.Status.Completed));
        orders.cancel(ref);
    }

    function test_Cancel_OnlyThePayer() public {
        bytes32 ref = _setUp(bob, RENT, PAYMENTS);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StandingOrders.NotItsPayer.selector, ref, bob));
        orders.cancel(ref);
    }

    /// @dev Over any run of setting up, paying, holds and cancelling, the module holds nothing between calls,
    /// what it is committed to stays within the allowance, and the books balance.
    function testFuzz_HoldsNothingAndBooksBalance(uint8[10] calldata ops, uint32[10] calldata amounts) public {
        bytes32[] memory refs = new bytes32[](ops.length);
        uint256 count;
        for (uint256 i = 0; i < ops.length; ++i) {
            uint256 op = ops[i] % 4;
            if (op == 0) {
                refs[count++] = _setUp(ops[i] % 8 < 4 ? bob : address(0), bound(amounts[i], 1, 20_000 * HKD), 1 + (ops[i] / 8) % 6);
            } else if (op == 1) {
                vm.warp(block.timestamp + bound(amounts[i], 1, 3) * INSTALMENT_PERIOD);
                for (uint256 j = 0; j < count; ++j) {
                    if (orders.order(refs[j]).status != StandingOrders.Status.Active) continue;
                    _payDue(refs[j]);
                }
            } else if (op == 2) {
                _save(bound(amounts[i], 0, token.available(alice)));
            } else if (count > 0) {
                bytes32 ref = refs[amounts[i] % count];
                if (orders.order(ref).status == StandingOrders.Status.Active) {
                    vm.prank(alice);
                    orders.cancel(ref);
                }
            }
            assertEq(token.balanceOf(address(orders)), 0);
            assertLe(orders.committed(alice), token.allowance(alice, address(orders)));
            _assertBooksBalance();
        }
    }

    // Helpers

    /// @dev Alice sets up an order with the allowance for its payments, to Bob or to her landlord at another bank.
    function _setUp(address to, uint256 amount, uint256 count) private returns (bytes32 ref) {
        vm.startPrank(alice);
        token.approve(address(orders), token.allowance(alice, address(orders)) + amount * count);
        ref = orders.setUp(to, to == address(0) ? LANDLORD : bytes32(0), amount, count);
        vm.stopPrank();
    }

    /// @dev Alice moves money into her savings, which counts against no limit, leaving less to pay from.
    function _save(uint256 amount) private {
        if (amount == 0) return;
        vm.startPrank(alice);
        token.approve(address(savings), amount);
        savings.deposit(amount, alice);
        vm.stopPrank();
    }

    /// @dev The order's first payment is due and cannot be made: it is missed, frees what it committed and
    /// moves no money.
    function _assertMissed(bytes32 ref, uint256 balance) private {
        uint256 committed = orders.committed(alice);
        vm.expectEmit(address(orders));
        emit StandingOrders.OrderMissed(ref, 1, RENT);
        _payDue(ref);
        StandingOrders.Order memory o = orders.order(ref);
        assertEq(o.tried, 1);
        assertEq(o.paid, 0);
        assertEq(orders.committed(alice), committed - RENT);
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(address(orders)), 0);
    }

    /// @dev The payments module's reference for the payment `ref` made, from the recorded OrderPaid event.
    function _paymentRefPaid(bytes32 ref) private returns (bytes32) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(orders) || logs[i].topics[0] != StandingOrders.OrderPaid.selector) continue;
            if (logs[i].topics[1] != ref) continue;
            (, , bytes32 paymentRef) = abi.decode(logs[i].data, (uint256, uint256, bytes32));
            return paymentRef;
        }
        revert("no OrderPaid");
    }

    function _payDue(bytes32 ref) private {
        vm.prank(scheduler);
        orders.payDue(ref);
    }
}
