// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CustomerLimits} from "./CustomerLimits.sol";
import {DepositToken} from "./DepositToken.sol";
import {Payments} from "./Payments.sol";

/// @dev The standing orders module. A customer sets an order up from their own account, naming a payee on
/// their register and in effect, the amount and the number of monthly payments, and in the same batch
/// allows the module to take what their orders will pay; the module refuses an order the allowance does
/// not cover. The scheduler triggers each order, and every payment due is made, oldest first, each whole
/// or not at all: to a customer of the bank through the module, which keeps its own channel, so the
/// payment counts against neither daily limit and leaves nothing behind if it cannot land, and to a payee
/// at another bank through the payments module, which screens and queues it as any payment out. A
/// payment the account cannot cover is missed and not tried again. The customer may cancel an order at
/// any time. Nothing is paid, or missed, while the bank is paused; the dates it held up are paid once it
/// resumes. See open questions 30 and 31 in docs/plan.md.
contract StandingOrders is AccessManaged {
    enum Status {
        None,
        Active,
        Cancelled,
        Completed
    }

    struct Order {
        address payer;
        /// @dev A customer of the bank, or zero for a payee at another bank, named by `payee` alone.
        address to;
        bytes32 payee;
        uint256 amount;
        uint48 setUpAt;
        Status status;
        uint256 payments;
        /// @dev Payments tried so far, made or missed, and those made.
        uint256 tried;
        uint256 paid;
    }

    DepositToken public immutable token;
    CustomerLimits public immutable limits;
    Payments public immutable payments;
    /// @dev The time between payments: a month, the loan schedule's period.
    uint256 public immutable period;

    uint256 public orderCount;
    mapping(bytes32 ref => Order) private _orders;
    /// @dev What each customer's active orders may still take, which their allowance must cover.
    mapping(address customer => uint256) public committed;

    event OrderSetUp(bytes32 indexed ref, address indexed payer, address indexed to, bytes32 payee, uint256 amount, uint256 payments);
    event OrderPaid(bytes32 indexed ref, uint256 number, uint256 amount, bytes32 paymentRef);
    event OrderMissed(bytes32 indexed ref, uint256 number, uint256 amount);
    event OrderCancelled(bytes32 indexed ref);
    event OrderCompleted(bytes32 indexed ref);

    error PayeeNotInEffect(address payer, bytes32 payee);
    error NotACustomer(address to);
    error MandateTooSmall(uint256 mandate, uint256 needed);
    error ZeroAmount();
    error NoPayments();
    error NotActive(bytes32 ref, Status status);
    error NotItsPayer(bytes32 ref, address caller);
    error PaymentNotTried(bytes32 ref);
    error OnlySelf();

    constructor(address manager, Payments payments_, uint256 period_) AccessManaged(manager) {
        payments = payments_;
        token = payments_.token();
        limits = token.customerLimits();
        period = period_;
        // The module hands the payments module what a payment to another bank takes.
        token.approve(address(payments_), type(uint256).max);
    }

    function order(bytes32 ref) external view returns (Order memory) {
        return _orders[ref];
    }

    /// @dev Payments that have fallen due by now, the first a month after the order was set up.
    function paymentsDue(bytes32 ref) public view returns (uint256) {
        Order storage o = _orders[ref];
        if (o.status == Status.None) return 0;
        return Math.min(o.payments, (block.timestamp - o.setUpAt) / period);
    }

    /// @dev Sets up an order from the caller's account: to `to`, an enrolled customer of the bank, whose payee
    /// is their address and `payee` is ignored, or with `to` zero to the payee at another bank whose details
    /// hash to `payee`. Either way the payee must be on the caller's register and in effect.
    function setUp(address to, bytes32 payee, uint256 amount, uint256 count) external returns (bytes32 ref) {
        if (amount == 0) revert ZeroAmount();
        if (count == 0) revert NoPayments();
        if (to != address(0)) {
            if (!limits.enrolled(to)) revert NotACustomer(to);
            payee = limits.payeeOf(to);
        }
        if (!limits.isPayee(msg.sender, payee)) revert PayeeNotInEffect(msg.sender, payee);
        uint256 needed = committed[msg.sender] + amount * count;
        uint256 mandate = token.allowance(msg.sender, address(this));
        if (mandate < needed) revert MandateTooSmall(mandate, needed);
        committed[msg.sender] = needed;

        ref = keccak256(abi.encode(block.chainid, address(this), ++orderCount));
        _orders[ref] = Order(msg.sender, to, payee, amount, uint48(block.timestamp), Status.Active, count, 0, 0);
        emit OrderSetUp(ref, msg.sender, to, payee, amount, count);
    }

    /// @dev The payer stops the order; nothing more is paid under it.
    function cancel(bytes32 ref) external {
        Order storage o = _active(ref);
        if (o.payer != msg.sender) revert NotItsPayer(ref, msg.sender);
        o.status = Status.Cancelled;
        committed[o.payer] -= o.amount * (o.payments - o.tried);
        emit OrderCancelled(ref);
    }

    /// @dev Makes every payment of the order due by now, oldest first. One the account cannot cover is
    /// missed and not tried again. A second trigger finds nothing more due.
    function payDue(bytes32 ref) external restricted {
        if (token.paused()) revert Pausable.EnforcedPause();
        Order storage o = _active(ref);
        uint256 due = paymentsDue(ref);
        while (o.tried < due) {
            uint256 number = ++o.tried;
            committed[o.payer] -= o.amount;
            try this.deliver(o.payer, o.to, o.payee, o.amount) returns (bytes32 paymentRef) {
                o.paid += 1;
                emit OrderPaid(ref, number, o.amount, paymentRef);
            } catch (bytes memory reason) {
                // The token names every refusal; a call that ran out of gas names none, and is no missed payment.
                if (reason.length == 0) revert PaymentNotTried(ref);
                emit OrderMissed(ref, number, o.amount);
            }
        }
        if (o.tried == o.payments) {
            o.status = Status.Completed;
            emit OrderCompleted(ref);
        }
    }

    /// @dev One payment, as a call of the module's own so that a payment that cannot land undoes the money
    /// taken for it: through the module to a customer of the bank, or into the payments module for another bank.
    function deliver(address payer, address to, bytes32 payee, uint256 amount) external returns (bytes32 paymentRef) {
        if (msg.sender != address(this)) revert OnlySelf();
        token.transferFrom(payer, address(this), amount);
        if (to != address(0)) {
            token.transfer(to, amount);
            return bytes32(0);
        }
        return payments.payFor(payer, amount, payee);
    }

    function _active(bytes32 ref) private view returns (Order storage o) {
        o = _orders[ref];
        if (o.status != Status.Active) revert NotActive(ref, o.status);
    }
}
