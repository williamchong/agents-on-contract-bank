// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AccountRecovery} from "./AccountRecovery.sol";
import {DepositToken} from "./DepositToken.sol";
import {Roles} from "./Roles.sol";

/// @dev The branch approval ladder, for the modules that hold the operations a teller opens for a
/// customer. A teller of the branch opens an operation, and the customer's money moves into the module
/// at once, so it cannot be spent twice while it waits: by the customer's own EIP-3009 authorisation
/// from a device or card, or on paper by a forced transfer of no more than the customer's unfrozen
/// balance. The ladder in docs/roles.md sets how many approve and in what order: a supervisor of the
/// branch, then its branch manager, then compliance. Each approver differs from the teller and every
/// earlier one. The last approval carries the operation out; the approver due next may refuse it and
/// the teller may cancel it, which gives the money back. The teller, the approvers and the slip's hash
/// stay on record. Staff who recovered a customer's account are refused as the teller or an approver of
/// that customer's operations. See open questions 19 and 21 in docs/plan.md.
abstract contract BranchApprovals is AccessManaged {
    /// @dev The customer's own signature, from a device or a card, or a teller's attestation to an
    /// in-person check on paper.
    enum Authorisation {
        Signed,
        Paper
    }

    enum Status {
        None,
        Waiting,
        CarriedOut,
        Refused,
        Cancelled
    }

    /// @dev A customer's EIP-3009 authorisation of a transfer to the module, from a device or a card,
    /// as a teller or an ATM submits it. Its one-use number's key is the operation's intent, so a teller
    /// cannot use it for another purpose, branch or recipient; see {intentKey}.
    struct CardAuthorisation {
        address customer;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
        bytes signature;
    }

    struct Operation {
        address teller;
        uint64 branch;
        Authorisation authorisation;
        uint8 required;
        uint8 approved;
        Status status;
        address customer;
        /// @dev Who receives the money, for a module that pays it to someone; zero otherwise.
        address recipient;
        uint256 amount;
        bytes32 slipHash;
        address[3] approvers;
    }

    /// @dev The ladder's steps: up to `first` a teller alone, or with a supervisor on paper; up to
    /// `second` one approver more; above it one more again.
    struct Ladder {
        uint256 first;
        uint256 second;
    }

    DepositToken public immutable token;
    AccountRecovery public immutable recovery;

    Ladder public ladder;
    uint256 public operationCount;
    /// @dev The customers' money the module holds for operations still waiting for their approvers.
    uint256 public waitingTotal;
    mapping(bytes32 ref => Operation) private _operations;

    event OperationOpened(
        bytes32 indexed ref,
        address indexed customer,
        address indexed teller,
        uint64 branch,
        uint256 amount,
        Authorisation authorisation,
        bytes32 slipHash,
        uint8 required
    );
    event OperationApproved(bytes32 indexed ref, address indexed approver, uint64 role, uint8 approved);
    event OperationCarriedOut(bytes32 indexed ref, address indexed customer, uint256 amount);
    event OperationRefused(bytes32 indexed ref, address indexed by);
    event OperationCancelled(bytes32 indexed ref);
    event LadderSet(Ladder ladder);

    error NotTeller(address caller, uint64 branch);
    error NotApprover(address caller, uint64 role);
    error TellerCannotApprove(address caller, bytes32 ref);
    error AlreadyApproved(address caller, bytes32 ref);
    error NotWaiting(bytes32 ref, Status status);
    error NotItsTeller(bytes32 ref, address caller);
    error BlockedCustomer(address customer);
    error InsufficientUnfrozen(address customer, uint256 available, uint256 amount);
    error AuthorisedForAnotherIntent(bytes32 nonce);
    error InvalidLadder(Ladder ladder);
    error RecoveredTheAccount(address staff, address customer);
    error NoSlip();
    error ZeroAmount();

    constructor(address manager, DepositToken token_, AccountRecovery recovery_, Ladder memory ladder_) AccessManaged(manager) {
        token = token_;
        recovery = recovery_;
        _setLadder(ladder_);
    }

    function operation(bytes32 ref) external view returns (Operation memory) {
        return _operations[ref];
    }

    /// @dev How many approvers an operation of `amount` needs besides the teller.
    function approversRequired(uint256 amount, Authorisation authorisation) public view returns (uint8 n) {
        if (amount > ladder.first) ++n;
        if (amount > ladder.second) ++n;
        if (authorisation == Authorisation.Paper) ++n;
    }

    /// @dev The role whose holder approves next, or zero once none is due.
    function nextApproverRole(bytes32 ref) public view returns (uint64) {
        Operation storage op = _operations[ref];
        if (op.status != Status.Waiting) return 0;
        return _approverRole(op.branch, op.approved);
    }

    /// @dev The key of the one-use number a customer's authorisation must carry for an operation of
    /// `purpose` at `branch` paying `recipient`, so it cannot be redeemed for anything else. The token
    /// counts uses per key, so each authorisation for the same intent still takes the next number.
    function intentKey(bytes32 purpose, uint64 branch, address recipient) public view returns (uint192) {
        return uint192(uint256(keccak256(abi.encode(address(this), purpose, branch, recipient))));
    }

    function setLadder(Ladder calldata ladder_) external restricted {
        _setLadder(ladder_);
    }

    /// @dev The next approver, holding the role the ladder names next, approves. The last approval
    /// carries the operation out, while its teller still holds the role and the customer is not blocked.
    function approve(bytes32 ref) external {
        Operation storage op = _waiting(ref);
        uint8 approved = op.approved;
        uint64 role = _checkApprover(op, ref, approved);
        op.approvers[approved] = msg.sender;
        op.approved = approved + 1;
        emit OperationApproved(ref, msg.sender, role, approved + 1);
        if (approved + 1 == op.required) _finish(ref, op);
    }

    /// @dev The approver due next refuses the operation, and the money goes back to the customer.
    function refuse(bytes32 ref) external {
        Operation storage op = _waiting(ref);
        _checkApprover(op, ref, op.approved);
        op.status = Status.Refused;
        _giveBack(op);
        emit OperationRefused(ref, msg.sender);
    }

    /// @dev The teller who opened the operation cancels it, and the money goes back to the customer.
    function cancel(bytes32 ref) external {
        Operation storage op = _waiting(ref);
        if (op.teller != msg.sender) revert NotItsTeller(ref, msg.sender);
        op.status = Status.Cancelled;
        _giveBack(op);
        emit OperationCancelled(ref);
    }

    // Internal

    /// @dev Opens an operation of `purpose` paying `recipient` on the customer's own authorisation,
    /// which must be for that intent, moves the money in, and carries it out if no approver is due.
    function _openSigned(
        uint64 branch,
        bytes32 purpose,
        address recipient,
        CardAuthorisation calldata a
    ) internal returns (bytes32 ref) {
        _requireTeller(branch);
        _receive(a, intentKey(purpose, branch, recipient));
        ref = _open(branch, a.customer, recipient, a.amount, Authorisation.Signed, 0);
    }

    /// @dev Opens an operation paying `recipient` on a paper instruction, moving no more than the
    /// customer's unfrozen balance in by forced transfer, which cuts through freezes and blocks.
    function _openOnPaper(
        uint64 branch,
        address customer,
        address recipient,
        uint256 amount,
        bytes32 slipHash
    ) internal returns (bytes32 ref) {
        _requireTeller(branch);
        if (slipHash == 0) revert NoSlip();
        if (!token.canTransact(customer)) revert BlockedCustomer(customer);
        uint256 unfrozen = token.available(customer);
        if (amount > unfrozen) revert InsufficientUnfrozen(customer, unfrozen, amount);
        token.forcedTransfer(customer, address(this), amount);
        ref = _open(branch, customer, recipient, amount, Authorisation.Paper, slipHash);
    }

    /// @dev Moves a customer's authorised amount into the module, checking the authorisation was given
    /// for the intent whose key is `key`.
    function _receive(CardAuthorisation calldata a, uint192 key) internal {
        if (uint192(uint256(a.nonce) >> 64) != key) revert AuthorisedForAnotherIntent(a.nonce);
        token.receiveWithAuthorization(a.customer, address(this), a.amount, a.validAfter, a.validBefore, a.nonce, a.signature);
    }

    function _requireTeller(uint64 branch) internal view {
        if (!_has(Roles.atBranch(branch, Roles.TELLER), msg.sender)) revert NotTeller(msg.sender, branch);
    }

    /// @dev What the module does with the money once every approver has approved.
    function _carryOut(bytes32 ref, Operation storage op) internal virtual;

    function _open(
        uint64 branch,
        address customer,
        address recipient,
        uint256 amount,
        Authorisation authorisation,
        bytes32 slipHash
    ) private returns (bytes32 ref) {
        if (amount == 0) revert ZeroAmount();
        _checkNotRecoveredBy(customer);
        ref = _nextRef();
        uint8 required = approversRequired(amount, authorisation);
        Operation storage op = _operations[ref];
        (op.teller, op.branch, op.authorisation, op.required, op.status) = (msg.sender, branch, authorisation, required, Status.Waiting);
        (op.customer, op.recipient, op.amount, op.slipHash) = (customer, recipient, amount, slipHash);
        waitingTotal += amount;
        emit OperationOpened(ref, customer, msg.sender, branch, amount, authorisation, slipHash, required);
        if (required == 0) _finish(ref, op);
    }

    function _finish(bytes32 ref, Operation storage op) private {
        (address teller, uint64 branch, address customer, uint256 amount) = (op.teller, op.branch, op.customer, op.amount);
        if (!_has(Roles.atBranch(branch, Roles.TELLER), teller)) revert NotTeller(teller, branch);
        if (!token.canTransact(customer)) revert BlockedCustomer(customer);
        op.status = Status.CarriedOut;
        waitingTotal -= amount;
        _carryOut(ref, op);
        emit OperationCarriedOut(ref, customer, amount);
    }

    /// @dev A customer blocked since cannot be given money back, so the refusal or cancellation waits
    /// until compliance lifts the block, as a rejected payment does.
    function _giveBack(Operation storage op) private {
        waitingTotal -= op.amount;
        token.transfer(op.customer, op.amount);
    }

    function _checkApprover(Operation storage op, bytes32 ref, uint8 approved) private view returns (uint64 role) {
        role = _approverRole(op.branch, approved);
        if (!_has(role, msg.sender)) revert NotApprover(msg.sender, role);
        if (msg.sender == op.teller) revert TellerCannotApprove(msg.sender, ref);
        _checkNotRecoveredBy(op.customer);
        for (uint256 i = 0; i < approved; ++i) if (op.approvers[i] == msg.sender) revert AlreadyApproved(msg.sender, ref);
    }

    /// @dev Staff who recovered this customer's account may not act for them at the branch, so a signer
    /// they enrolled cannot be used by them.
    function _checkNotRecoveredBy(address customer) private view {
        if (recovery.involved(customer, msg.sender)) revert RecoveredTheAccount(msg.sender, customer);
    }

    /// @dev The ladder's approvers in order: a supervisor of the branch, its branch manager, compliance.
    function _approverRole(uint64 branch, uint8 step) private pure returns (uint64) {
        if (step == 0) return Roles.atBranch(branch, Roles.SUPERVISOR);
        if (step == 1) return Roles.atBranch(branch, Roles.BRANCH_MANAGER);
        return Roles.COMPLIANCE;
    }

    function _setLadder(Ladder memory ladder_) private {
        if (ladder_.first > ladder_.second) revert InvalidLadder(ladder_);
        ladder = ladder_;
        emit LadderSet(ladder_);
    }

    function _waiting(bytes32 ref) private view returns (Operation storage op) {
        op = _operations[ref];
        if (op.status != Status.Waiting) revert NotWaiting(ref, op.status);
    }

    function _nextRef() internal returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), ++operationCount));
    }

    function _has(uint64 role, address account) internal view returns (bool member) {
        (member, ) = IAccessManager(authority()).hasRole(role, account);
    }
}
