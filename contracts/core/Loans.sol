// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AccountRecovery} from "./AccountRecovery.sol";
import {LendingGuard} from "./LendingGuard.sol";
import {Roles} from "./Roles.sol";

/// @dev The loans module, which holds a loan from its proposal to its drawdown. The credit officer
/// proposes a loan to a customer at a branch, at the loan rate and term in force, and may cancel it
/// until it is drawn. A supervisor of that branch, someone other than the proposer, approves or refuses
/// it, and the lending caps are checked then, as a limits system does: each customer's exposure and the
/// total, counting loans outstanding and loans approved and not yet drawn, so two approvals cannot
/// together pass a cap each fits. The customer accepts from their own account, and the acceptance draws
/// the loan through the lending guard in the same transaction; a drawdown the guard refuses undoes the
/// acceptance and leaves the loan approved. Staff may not propose or approve a loan to themselves, or to
/// a customer whose account they recovered. The module holds the lender role and no money. See open question 25 in
/// docs/plan.md.
contract Loans is AccessManaged {
    enum Status {
        None,
        Proposed,
        Approved,
        Drawn,
        Refused,
        Cancelled
    }

    /// @dev The loan rate a year and the number of monthly instalments, as a loan is proposed at.
    struct Terms {
        uint256 rateBps;
        uint256 instalments;
    }

    struct Caps {
        uint256 perCustomer;
        uint256 total;
    }

    struct Loan {
        address borrower;
        uint64 branch;
        Status status;
        address officer;
        address approver;
        uint48 drawnAt;
        uint256 amount;
        Terms terms;
    }

    LendingGuard public immutable guard;
    AccountRecovery public immutable recovery;

    Terms public terms;
    Caps public caps;
    uint256 public loanCount;
    /// @dev Loans outstanding and loans approved and not yet drawn, in all and to each customer.
    uint256 public totalExposure;
    mapping(address customer => uint256) public exposure;
    mapping(bytes32 ref => Loan) private _loans;

    event LoanProposed(bytes32 indexed ref, address indexed borrower, address indexed officer, uint64 branch, uint256 amount, Terms terms);
    event LoanApproved(bytes32 indexed ref, address indexed approver);
    event LoanRefused(bytes32 indexed ref, address indexed by);
    event LoanCancelled(bytes32 indexed ref);
    event LoanDrawn(bytes32 indexed ref, address indexed borrower, uint256 amount);
    event TermsSet(Terms terms);
    event CapsSet(Caps caps);

    error NotSupervisor(address caller, uint64 branch);
    error NotCreditOfficer(address officer);
    error OfficerCannotApprove(address caller, bytes32 ref);
    error NotItsOfficer(bytes32 ref, address caller);
    error NotItsBorrower(bytes32 ref, address caller);
    error NotProposed(bytes32 ref, Status status);
    error NotApproved(bytes32 ref, Status status);
    error NotOpen(bytes32 ref, Status status);
    error PerCustomerCapExceeded(address customer, uint256 exposure, uint256 cap);
    error TotalCapExceeded(uint256 exposure, uint256 cap);
    error RecoveredTheAccount(address staff, address customer);
    error OwnLoan(address staff);
    error ZeroAmount();

    constructor(
        address manager,
        LendingGuard guard_,
        AccountRecovery recovery_,
        Terms memory terms_,
        Caps memory caps_
    ) AccessManaged(manager) {
        guard = guard_;
        recovery = recovery_;
        _setTerms(terms_);
        _setCaps(caps_);
    }

    function loan(bytes32 ref) external view returns (Loan memory) {
        return _loans[ref];
    }

    function setTerms(Terms calldata terms_) external restricted {
        _setTerms(terms_);
    }

    function setCaps(Caps calldata caps_) external restricted {
        _setCaps(caps_);
    }

    /// @dev The credit officer proposes a loan of `amount` to `borrower`, for a supervisor of `branch` to
    /// approve, at the terms in force now.
    function propose(address borrower, uint64 branch, uint256 amount) external restricted returns (bytes32 ref) {
        if (amount == 0) revert ZeroAmount();
        // Refuses a branch that cannot have a supervisor to approve the loan.
        Roles.atBranch(branch, Roles.SUPERVISOR);
        _checkNotOwnOrRecovered(borrower);
        ref = keccak256(abi.encode(block.chainid, address(this), ++loanCount));
        _loans[ref] = Loan(borrower, branch, Status.Proposed, msg.sender, address(0), 0, amount, terms);
        emit LoanProposed(ref, borrower, msg.sender, branch, amount, terms);
    }

    /// @dev A supervisor of the loan's branch approves it within the lending caps.
    function approve(bytes32 ref) external {
        Loan storage l = _proposed(ref);
        _checkApprover(l, ref);
        uint256 customerExposure = exposure[l.borrower] + l.amount;
        if (customerExposure > caps.perCustomer) revert PerCustomerCapExceeded(l.borrower, customerExposure, caps.perCustomer);
        uint256 total = totalExposure + l.amount;
        if (total > caps.total) revert TotalCapExceeded(total, caps.total);
        exposure[l.borrower] = customerExposure;
        totalExposure = total;
        (l.status, l.approver) = (Status.Approved, msg.sender);
        emit LoanApproved(ref, msg.sender);
    }

    /// @dev A supervisor of the loan's branch refuses it.
    function refuse(bytes32 ref) external {
        Loan storage l = _proposed(ref);
        _checkApprover(l, ref);
        l.status = Status.Refused;
        emit LoanRefused(ref, msg.sender);
    }

    /// @dev The credit officer who proposed the loan cancels it before it is drawn.
    function cancel(bytes32 ref) external {
        Loan storage l = _loans[ref];
        if (l.status != Status.Proposed && l.status != Status.Approved) revert NotOpen(ref, l.status);
        if (l.officer != msg.sender) revert NotItsOfficer(ref, msg.sender);
        if (l.status == Status.Approved) _release(l);
        l.status = Status.Cancelled;
        emit LoanCancelled(ref);
    }

    /// @dev The borrower accepts the loan's terms from their own account, and it is drawn through the
    /// lending guard, while its credit officer still holds the role.
    function accept(bytes32 ref) external {
        Loan storage l = _loans[ref];
        if (l.status != Status.Approved) revert NotApproved(ref, l.status);
        if (l.borrower != msg.sender) revert NotItsBorrower(ref, msg.sender);
        if (!_has(Roles.CREDIT_OFFICER, l.officer)) revert NotCreditOfficer(l.officer);
        (l.status, l.drawnAt) = (Status.Drawn, uint48(block.timestamp));
        guard.drawdown(l.borrower, l.amount, ref);
        emit LoanDrawn(ref, l.borrower, l.amount);
    }

    // Internal

    function _proposed(bytes32 ref) private view returns (Loan storage l) {
        l = _loans[ref];
        if (l.status != Status.Proposed) revert NotProposed(ref, l.status);
    }

    function _checkApprover(Loan storage l, bytes32 ref) private view {
        if (!_has(Roles.atBranch(l.branch, Roles.SUPERVISOR), msg.sender)) revert NotSupervisor(msg.sender, l.branch);
        if (msg.sender == l.officer) revert OfficerCannotApprove(msg.sender, ref);
        _checkNotOwnOrRecovered(l.borrower);
    }

    function _release(Loan storage l) private {
        exposure[l.borrower] -= l.amount;
        totalExposure -= l.amount;
    }

    /// @dev Staff hold accounts of their own, and may not lend to themselves. Nor may staff who recovered
    /// this customer's account, so they cannot arrange a loan that a signer they enrolled would accept.
    function _checkNotOwnOrRecovered(address customer) private view {
        if (customer == msg.sender) revert OwnLoan(msg.sender);
        if (recovery.involved(customer, msg.sender)) revert RecoveredTheAccount(msg.sender, customer);
    }

    function _setTerms(Terms memory terms_) private {
        terms = terms_;
        emit TermsSet(terms_);
    }

    function _setCaps(Caps memory caps_) private {
        caps = caps_;
        emit CapsSet(caps_);
    }

    function _has(uint64 role, address account) private view returns (bool member) {
        (member, ) = IAccessManager(authority()).hasRole(role, account);
    }
}
