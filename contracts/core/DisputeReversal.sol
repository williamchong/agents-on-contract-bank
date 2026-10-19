// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DepositToken} from "./DepositToken.sol";
import {HoldRegister} from "./HoldRegister.sol";
import {Roles} from "./Roles.sol";

/// @dev The dispute reversal module. Support opens a dispute on a customer's behalf, naming the operation,
/// its recipient and its amount, and the module places a hold of that amount on the recipient at once, a
/// hold of its own that only it or compliance lifts. Back office proposes the reversal and compliance,
/// someone else, approves it: the module lifts its own hold and takes back by forced transfer what is
/// still in the recipient's account, up to the amount and never into another hold, and returns it to the
/// customer, so the token's frozen amount and the register stay in step. A dispute compliance rejects
/// lifts the hold and moves nothing. An operation is disputed once, and support, back office and compliance
/// are three different people. It holds the enforcer and dispute holder roles. Who may call is decided
/// here, not by the access manager, as the three must differ. See open question 21 in docs/plan.md.
contract DisputeReversal {
    enum Status {
        None,
        Open,
        Proposed,
        Reversed,
        Rejected
    }

    struct Dispute {
        address customer;
        address recipient;
        uint256 amount;
        bytes32 operationRef;
        uint256 holdId;
        address openedBy;
        address proposedBy;
        Status status;
    }

    string private constant HOLD_REASON = "dispute";

    AccessManager public immutable manager;
    DepositToken public immutable token;
    HoldRegister public immutable holds;

    uint256 public disputeCount;
    mapping(uint256 id => Dispute) private _disputes;
    mapping(bytes32 operationRef => bool) public disputed;

    event DisputeOpened(
        uint256 indexed id,
        address indexed customer,
        address indexed recipient,
        uint256 amount,
        bytes32 operationRef,
        address openedBy
    );
    event ReversalProposed(uint256 indexed id, address indexed by);
    event DisputeReversed(uint256 indexed id, address indexed customer, address indexed recipient, uint256 returned, address proposedBy, address approvedBy);
    event DisputeRejected(uint256 indexed id, address indexed by);

    error NotRole(address caller, uint64 role);
    error NotStatus(uint256 id, Status status);
    error AlreadyActed(address caller, uint256 id);
    error AlreadyDisputed(bytes32 operationRef);
    error CannotRepay(address customer);
    error ZeroAmount();

    constructor(AccessManager manager_, DepositToken token_, HoldRegister holds_) {
        manager = manager_;
        token = token_;
        holds = holds_;
    }

    function dispute(uint256 id) external view returns (Dispute memory) {
        return _disputes[id];
    }

    /// @dev Support opens a dispute of `operationRef`, which paid `amount` from `customer` to `recipient`,
    /// and the recipient's money is frozen at once.
    function open(address customer, address recipient, uint256 amount, bytes32 operationRef) external returns (uint256 id) {
        _require(Roles.SUPPORT);
        if (amount == 0) revert ZeroAmount();
        if (disputed[operationRef]) revert AlreadyDisputed(operationRef);
        if (!token.canTransact(customer)) revert CannotRepay(customer);
        disputed[operationRef] = true;
        id = ++disputeCount;
        uint256 holdId = holds.place(recipient, amount, Roles.DISPUTE_HOLDER, HOLD_REASON);
        _disputes[id] = Dispute(customer, recipient, amount, operationRef, holdId, msg.sender, address(0), Status.Open);
        emit DisputeOpened(id, customer, recipient, amount, operationRef, msg.sender);
    }

    /// @dev Back office proposes reversing an open dispute.
    function propose(uint256 id) external {
        _require(Roles.BACK_OFFICE);
        Dispute storage d = _status(id, Status.Open);
        if (msg.sender == d.openedBy) revert AlreadyActed(msg.sender, id);
        d.status = Status.Proposed;
        d.proposedBy = msg.sender;
        emit ReversalProposed(id, msg.sender);
    }

    /// @dev Compliance, someone other than whoever opened or proposed it, approves the reversal: the module lifts its own
    /// hold, then takes back what is still free in the recipient's account, up to the amount.
    function approve(uint256 id) external {
        _require(Roles.COMPLIANCE);
        Dispute storage d = _status(id, Status.Proposed);
        if (msg.sender == d.proposedBy || msg.sender == d.openedBy) revert AlreadyActed(msg.sender, id);
        d.status = Status.Reversed;
        holds.lift(d.holdId, Roles.DISPUTE_HOLDER);
        uint256 returned = Math.min(d.amount, token.available(d.recipient));
        if (returned != 0) token.forcedTransfer(d.recipient, d.customer, returned);
        emit DisputeReversed(id, d.customer, d.recipient, returned, d.proposedBy, msg.sender);
    }

    /// @dev Compliance rejects an open or proposed dispute: the hold is lifted and nothing moves.
    function reject(uint256 id) external {
        _require(Roles.COMPLIANCE);
        Dispute storage d = _disputes[id];
        if (d.status != Status.Open && d.status != Status.Proposed) revert NotStatus(id, d.status);
        d.status = Status.Rejected;
        holds.lift(d.holdId, Roles.DISPUTE_HOLDER);
        emit DisputeRejected(id, msg.sender);
    }

    function _status(uint256 id, Status status) private view returns (Dispute storage d) {
        d = _disputes[id];
        if (d.status != status) revert NotStatus(id, d.status);
    }

    function _require(uint64 role) private view {
        (bool member, ) = manager.hasRole(role, msg.sender);
        if (!member) revert NotRole(msg.sender, role);
    }
}
