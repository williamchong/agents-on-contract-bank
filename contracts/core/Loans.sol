// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccountRecovery} from "./AccountRecovery.sol";
import {DepositToken} from "./DepositToken.sol";
import {LendingGuard} from "./LendingGuard.sol";
import {Rates} from "./Rates.sol";
import {Roles} from "./Roles.sol";

/// @dev The loans module, which holds a loan from its proposal to its repayment or write-off. The credit
/// officer proposes a loan to a customer at a branch, at the loan rate in force and the bank's term, and
/// may cancel it until it is drawn. A supervisor of that branch, someone other than the proposer, approves or refuses
/// it, and the lending caps are checked then, as a limits system does: each customer's exposure and the
/// total, counting loans outstanding and loans approved and not yet drawn, so two approvals cannot
/// together pass a cap each fits. The customer accepts from their own account, with a mandate that lets
/// the module take the loan's instalments, and the acceptance draws the loan through the lending guard in
/// the same transaction; a drawdown the guard refuses undoes the acceptance and leaves the loan approved.
/// Staff may not propose or approve a loan to themselves, or to a customer whose account they recovered.
/// The borrower may cancel one loan's mandate, as a direct debit is stopped, and renew it. The scheduler
/// triggers each loan's collection, and every instalment due is taken under the mandate, oldest first,
/// each whole or not at all. A loan is in arrears while an instalment due is unpaid and in
/// default from the third, where it stays until governance writes it off; its allowance is measured
/// again at each collection and change of stage. The guard posts every entry, so the module, which holds
/// the lender role, cannot create money; it holds money only within a collection. See open questions 25
/// and 28 in docs/plan.md.
contract Loans is AccessManaged {
    using SafeCast for uint256;

    enum Status {
        None,
        Proposed,
        Approved,
        Drawn,
        Refused,
        Cancelled,
        Repaid,
        WrittenOff
    }

    /// @dev A drawn loan's stage, which its loss allowance follows.
    enum Stage {
        Performing,
        Arrears,
        Default
    }

    /// @dev The loan rate a year and the number of monthly instalments, as a loan is proposed at.
    struct Terms {
        uint256 rateBps;
        uint256 instalments;
    }

    /// @dev The number of instalments every loan is repaid in, and the time between them.
    struct Schedule {
        uint256 instalments;
        uint256 period;
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
        Stage stage;
        bool mandateCancelled;
        /// @dev Instalments collected, and instalments due and not collected at the last collection.
        uint256 paid;
        uint256 unpaid;
        /// @dev Each instalment but the last, which clears what is left.
        uint256 instalment;
        uint256 outstanding;
        uint256 allowance;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    /// @dev The unpaid instalment at which a loan is in default: the third, ninety days past due locally.
    uint256 public constant DEFAULT_AT = 3;

    LendingGuard public immutable guard;
    AccountRecovery public immutable recovery;
    DepositToken public immutable token;
    Rates public immutable rates;
    uint256 public immutable instalments;
    uint256 public immutable period;

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
    event InstalmentCollected(bytes32 indexed ref, uint256 number, uint256 principal, uint256 interest);
    /// @dev A collection found more instalments due and unpaid than the last one did.
    event CollectionMissed(bytes32 indexed ref, uint256 unpaid, Stage stage);
    event StageChanged(bytes32 indexed ref, Stage stage, uint256 allowance);
    event MandateCancelled(bytes32 indexed ref);
    event MandateRenewed(bytes32 indexed ref);
    event LoanRepaid(bytes32 indexed ref);
    event LoanWrittenOff(bytes32 indexed ref, uint256 principal, uint256 allowance);
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
    error NotDrawn(bytes32 ref, Status status);
    error NotInDefault(bytes32 ref, Stage stage);
    error MandateTooSmall(uint256 mandate, uint256 needed);
    error InvalidSchedule();
    error CollectionNotTried(bytes32 ref);

    constructor(
        address manager,
        LendingGuard guard_,
        AccountRecovery recovery_,
        Rates rates_,
        Schedule memory schedule,
        Caps memory caps_
    ) AccessManaged(manager) {
        if (schedule.instalments == 0 || schedule.period == 0) revert InvalidSchedule();
        guard = guard_;
        recovery = recovery_;
        token = guard_.ledger().token();
        rates = rates_;
        instalments = schedule.instalments;
        period = schedule.period;
        _setCaps(caps_);
    }

    function loan(bytes32 ref) external view returns (Loan memory) {
        return _loans[ref];
    }

    /// @dev The instalments due by now: one a period from the drawdown, up to the term.
    function instalmentsDue(bytes32 ref) public view returns (uint256) {
        Loan storage l = _loans[ref];
        if (l.drawnAt == 0) return 0;
        return Math.min((block.timestamp - l.drawnAt) / period, l.terms.instalments);
    }

    function setCaps(Caps calldata caps_) external restricted {
        _setCaps(caps_);
    }

    /// @dev The credit officer proposes a loan of `amount` to `borrower`, for a supervisor of `branch` to
    /// approve, at the loan rate in force now.
    function propose(address borrower, uint64 branch, uint256 amount) external restricted returns (bytes32 ref) {
        if (amount == 0) revert ZeroAmount();
        // Refuses a branch that cannot have a supervisor to approve the loan.
        Roles.atBranch(branch, Roles.SUPERVISOR);
        _checkNotOwnOrRecovered(borrower);
        ref = keccak256(abi.encode(block.chainid, address(this), ++loanCount));
        (, uint256 loanBps) = rates.products();
        Loan storage l = _loans[ref];
        (l.borrower, l.branch, l.status, l.officer, l.amount) = (borrower, branch, Status.Proposed, msg.sender, amount);
        l.terms = Terms(loanBps, instalments);
        emit LoanProposed(ref, borrower, msg.sender, branch, amount, l.terms);
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
        if (l.status == Status.Approved) _release(l.borrower, l.amount);
        l.status = Status.Cancelled;
        emit LoanCancelled(ref);
    }

    /// @dev The borrower accepts the loan's terms from their own account, with a mandate covering its
    /// instalments, and it is drawn through the lending guard, while its credit officer still holds the role.
    function accept(bytes32 ref) external {
        Loan storage l = _loans[ref];
        if (l.status != Status.Approved) revert NotApproved(ref, l.status);
        if (l.borrower != msg.sender) revert NotItsBorrower(ref, msg.sender);
        if (!_has(Roles.CREDIT_OFFICER, l.officer)) revert NotCreditOfficer(l.officer);
        uint256 instalment = annuity(l.amount, l.terms);
        uint256 needed = instalment * l.terms.instalments;
        uint256 mandate = token.allowance(l.borrower, address(this));
        if (mandate < needed) revert MandateTooSmall(mandate, needed);
        l.status = Status.Drawn;
        l.drawnAt = uint48(block.timestamp);
        l.instalment = instalment;
        l.outstanding = l.amount;
        l.allowance = guard.drawdown(l.borrower, l.amount, ref);
        emit LoanDrawn(ref, l.borrower, l.amount);
    }

    /// @dev The borrower stops the loan's instalments being taken, as they may stop any direct debit;
    /// each instalment then falls due unpaid.
    function cancelMandate(bytes32 ref) external {
        _ownDrawn(ref).mandateCancelled = true;
        emit MandateCancelled(ref);
    }

    /// @dev The borrower lets the loan's instalments be taken again, from the next that falls due.
    function renewMandate(bytes32 ref) external {
        _ownDrawn(ref).mandateCancelled = false;
        emit MandateRenewed(ref);
    }

    /// @dev Collects every instalment of the loan due by now, oldest first, until one cannot be taken,
    /// then sets its stage and measures its allowance again. A second trigger finds nothing more due.
    function collectDue(bytes32 ref) external restricted {
        // A collection the pause would refuse is no missed instalment; it is collected once the bank resumes.
        if (token.paused()) revert Pausable.EnforcedPause();
        Loan storage l = _loans[ref];
        if (l.status != Status.Drawn) revert NotDrawn(ref, l.status);
        uint256 due = instalmentsDue(ref);
        while (l.paid < due && l.outstanding > 0 && _collect(l, ref)) {}
        uint256 unpaid = l.outstanding == 0 ? 0 : due - l.paid;
        Stage stage = _stageFor(l.stage, unpaid);
        if (unpaid > l.unpaid) emit CollectionMissed(ref, unpaid, stage);
        l.unpaid = unpaid;
        bool restaged = stage != l.stage;
        l.stage = stage;
        _measure(l, ref);
        if (restaged) emit StageChanged(ref, stage, l.allowance);
        if (l.outstanding == 0) {
            l.status = Status.Repaid;
            emit LoanRepaid(ref);
        }
    }

    /// @dev Governance writes a defaulted loan off, against its allowance.
    function writeOff(bytes32 ref) external restricted {
        Loan storage l = _loans[ref];
        if (l.status != Status.Drawn) revert NotDrawn(ref, l.status);
        if (l.stage != Stage.Default) revert NotInDefault(ref, l.stage);
        (uint256 principal, uint256 allowance) = (l.outstanding, l.allowance);
        guard.writeOff(ref, principal, allowance);
        _release(l.borrower, principal);
        (l.status, l.outstanding, l.allowance) = (Status.WrittenOff, 0, 0);
        emit LoanWrittenOff(ref, principal, allowance);
    }

    /// @dev The equal monthly instalment that repays `amount` over the term at its rate, rounded up to the
    /// cent, so the last instalment is the one left smaller.
    function annuity(uint256 amount, Terms memory terms) public pure returns (uint256) {
        uint256 rate = (terms.rateBps * WAD) / (12 * BPS);
        if (rate == 0) return Math.ceilDiv(amount, terms.instalments);
        uint256 growth = WAD;
        for (uint256 i = 0; i < terms.instalments; ++i) growth = Math.mulDiv(growth, WAD + rate, WAD);
        return Math.mulDiv(amount * rate, growth, (growth - WAD) * WAD, Math.Rounding.Ceil);
    }

    // Internal

    function _proposed(bytes32 ref) private view returns (Loan storage l) {
        l = _loans[ref];
        if (l.status != Status.Proposed) revert NotProposed(ref, l.status);
    }

    function _ownDrawn(bytes32 ref) private view returns (Loan storage l) {
        l = _loans[ref];
        if (l.status != Status.Drawn) revert NotDrawn(ref, l.status);
        if (l.borrower != msg.sender) revert NotItsBorrower(ref, msg.sender);
    }

    function _checkApprover(Loan storage l, bytes32 ref) private view {
        if (!_has(Roles.atBranch(l.branch, Roles.SUPERVISOR), msg.sender)) revert NotSupervisor(msg.sender, l.branch);
        if (msg.sender == l.officer) revert OfficerCannotApprove(msg.sender, ref);
        _checkNotOwnOrRecovered(l.borrower);
    }

    /// @dev Takes the next instalment under the mandate, or reports that it could not: the mandate
    /// cancelled or too small, or the account short, frozen or blocked. Each pays the month's interest on
    /// what is outstanding, and the rest off the principal.
    function _collect(Loan storage l, bytes32 ref) private returns (bool) {
        if (l.mandateCancelled) return false;
        uint256 interest = Math.mulDiv(l.outstanding, l.terms.rateBps, 12 * BPS);
        bool last = l.paid + 1 == l.terms.instalments;
        uint256 amount = last ? l.outstanding + interest : Math.min(l.instalment, l.outstanding + interest);
        try token.transferFrom(l.borrower, address(this), amount) {} catch (bytes memory reason) {
            // The token names every refusal; a call that ran out of gas names none, and is no missed instalment.
            if (reason.length == 0) revert CollectionNotTried(ref);
            return false;
        }
        uint256 principal = amount - interest;
        l.paid += 1;
        l.outstanding -= principal;
        _release(l.borrower, principal);
        guard.collect(ref, principal, interest);
        emit InstalmentCollected(ref, l.paid, principal, interest);
        return true;
    }

    /// @dev Default is kept once reached; otherwise any instalment unpaid is arrears.
    function _stageFor(Stage current, uint256 unpaid) private pure returns (Stage) {
        if (current == Stage.Default || unpaid >= DEFAULT_AT) return Stage.Default;
        if (unpaid > 0) return Stage.Arrears;
        return Stage.Performing;
    }

    /// @dev Measures the loan's allowance again, at the rate for its stage on what is outstanding.
    function _measure(Loan storage l, bytes32 ref) private {
        uint256 allowance = Math.mulDiv(l.outstanding, _allowanceRate(l.stage), BPS, Math.Rounding.Ceil);
        if (allowance == l.allowance) return;
        guard.measure(ref, allowance.toInt256() - l.allowance.toInt256());
        l.allowance = allowance;
    }

    function _allowanceRate(Stage stage) private view returns (uint256) {
        (uint256 performing, uint256 arrears, uint256 defaulted) = rates.allowance();
        if (stage == Stage.Default) return defaulted;
        if (stage == Stage.Arrears) return arrears;
        return performing;
    }

    function _release(address customer, uint256 amount) private {
        exposure[customer] -= amount;
        totalExposure -= amount;
    }

    /// @dev Staff hold accounts of their own, and may not lend to themselves. Nor may staff who recovered
    /// this customer's account, so they cannot arrange a loan that a signer they enrolled would accept.
    function _checkNotOwnOrRecovered(address customer) private view {
        if (customer == msg.sender) revert OwnLoan(msg.sender);
        if (recovery.involved(customer, msg.sender)) revert RecoveredTheAccount(msg.sender, customer);
    }

    function _setCaps(Caps memory caps_) private {
        caps = caps_;
        emit CapsSet(caps_);
    }

    function _has(uint64 role, address account) private view returns (bool member) {
        (member, ) = IAccessManager(authority()).hasRole(role, account);
    }
}
