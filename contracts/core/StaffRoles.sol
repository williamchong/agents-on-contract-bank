// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {MultiSignerERC7913} from "@openzeppelin/contracts/utils/cryptography/signers/MultiSignerERC7913.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Roles} from "./Roles.sol";

/// @dev The admin of every staff and machine role in the access manager, holding the staff admin
/// role. Governance grants its roles at once; a branch manager's grants of their branch's roles
/// wait for IT security, and IT security's enrolment or retirement of an ATM waits for a
/// supervisor. Revoking is at once. Every grant is refused to its maker or approver, to an account
/// that shares a key with the governance account, and when it would complete a conflicting pair.
/// Who may call is decided here, not by the access manager, because it depends on the role asked
/// for. See the access manager roles in docs/roles.md.
contract StaffRoles {
    using EnumerableSet for EnumerableSet.UintSet;

    /// @dev A grant, or an ATM's retirement, waiting for its approver.
    struct Proposal {
        address maker;
        address account;
        uint64 role;
        bool grant;
    }

    AccessManager public immutable manager;
    /// @dev The officers' account behind the governance time lock, whose keys no staff account may share.
    MultiSignerERC7913 public immutable governanceAccount;

    uint256 public proposalCount;
    mapping(uint256 id => Proposal) private _proposals;
    /// @dev The roles granted here to each account, so the conflict check can see what it holds.
    mapping(address account => EnumerableSet.UintSet) private _granted;

    event Proposed(uint256 indexed id, address indexed maker, address indexed account, uint64 role, bool grant);
    event Cancelled(uint256 indexed id);
    event Granted(address indexed account, uint64 indexed role, address maker, address approver);
    event Revoked(address indexed account, uint64 indexed role, address by);

    error NotAdministered(uint64 role);
    error NotGrantor(address caller, uint64 role);
    error NotRevoker(address caller, uint64 role);
    error NotApprover(address caller, uint64 approverRole);
    error NotMaker(address caller, uint256 id);
    error NoSuchProposal(uint256 id);
    error ApproverIsMaker(address approver);
    error SelfGrant(address account);
    error NotAStaffAccount(address account);
    error GovernanceSigner(address account);
    error ConflictingRoles(address account, uint64 held, uint64 role);

    constructor(AccessManager manager_, MultiSignerERC7913 governanceAccount_) {
        manager = manager_;
        governanceAccount = governanceAccount_;
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    /// @dev The control and assurance roles, the scheduler and branch managers, granted by governance.
    function grant(address account, uint64 role) external {
        bool governs = role == Roles.SCHEDULER ||
            (role >= Roles.RISK && role <= Roles.INTERNAL_AUDIT) ||
            Roles.branchRole(role) == Roles.BRANCH_MANAGER;
        if (!governs || !_holds(Roles.GOVERNANCE, msg.sender)) revert NotGrantor(msg.sender, role);
        _grant(account, role, msg.sender, address(0));
    }

    /// @dev A branch manager's grant of their branch's roles, or IT security's enrolment
    /// (`grant_` true) or retirement of an ATM. Checked now, and again when approved.
    function propose(address account, uint64 role, bool grant_) external returns (uint256 id) {
        if (!_mayPropose(msg.sender, role) || (!grant_ && role != Roles.ATM)) revert NotGrantor(msg.sender, role);
        if (grant_) _checkGrant(account, role, msg.sender, address(0));
        id = ++proposalCount;
        _proposals[id] = Proposal(msg.sender, account, role, grant_);
        emit Proposed(id, msg.sender, account, role, grant_);
    }

    /// @dev Approves a proposal as the holder of `approverRole`: IT security for a branch role, or a
    /// supervisor at any branch for an ATM.
    function approve(uint256 id, uint64 approverRole) external {
        Proposal memory p = _proposal(id);
        bool fits = p.role == Roles.ATM
            ? Roles.branchRole(approverRole) == Roles.SUPERVISOR
            : approverRole == Roles.IT_SECURITY;
        if (!fits || !_holds(approverRole, msg.sender)) revert NotApprover(msg.sender, approverRole);
        if (msg.sender == p.maker) revert ApproverIsMaker(msg.sender);
        if (!_mayPropose(p.maker, p.role)) revert NotGrantor(p.maker, p.role);

        delete _proposals[id];
        if (p.grant) _grant(p.account, p.role, p.maker, msg.sender);
        else _revoke(p.account, p.role, msg.sender);
    }

    function cancel(uint256 id) external {
        if (_proposal(id).maker != msg.sender) revert NotMaker(msg.sender, id);
        delete _proposals[id];
        emit Cancelled(id);
    }

    /// @dev At once, with no second party: a branch manager for their branch's roles other than
    /// branch manager, and risk or governance for any role administered here.
    function revoke(address account, uint64 role) external {
        if (!_administers(role)) revert NotAdministered(role);
        bool branchManager = Roles.isBranchRole(role) &&
            Roles.branchRole(role) != Roles.BRANCH_MANAGER &&
            _holds(Roles.atBranch(Roles.branchOf(role), Roles.BRANCH_MANAGER), msg.sender);
        if (!branchManager && !_holds(Roles.RISK, msg.sender) && !_holds(Roles.GOVERNANCE, msg.sender)) {
            revert NotRevoker(msg.sender, role);
        }
        _revoke(account, role, msg.sender);
    }

    function _grant(address account, uint64 role, address maker, address approver) private {
        _checkGrant(account, role, maker, approver);
        _granted[account].add(role);
        manager.grantRole(role, account, 0);
        emit Granted(account, role, maker, approver);
    }

    function _revoke(address account, uint64 role, address by) private {
        _granted[account].remove(role);
        manager.revokeRole(role, account);
        emit Revoked(account, role, by);
    }

    function _checkGrant(address account, uint64 role, address maker, address approver) private view {
        if (account == maker || account == approver) revert SelfGrant(account);
        if (Roles.isStaffRole(role)) _checkNotGovernanceSigner(account);
        uint256[] memory held = _granted[account].values();
        for (uint256 i = 0; i < held.length; ++i) {
            uint64 h = uint64(held[i]);
            // A role renounced at the access manager no longer counts.
            if (Roles.conflicts(h, role) && _holds(h, account)) revert ConflictingRoles(account, h, role);
        }
    }

    /// @dev A staff member acts from a multi-signer account, so its keys can be listed and each
    /// looked up on the governance account.
    function _checkNotGovernanceSigner(address account) private view {
        if (account.code.length == 0) revert NotAStaffAccount(account);
        bytes[] memory keys;
        try MultiSignerERC7913(account).getSigners(0, type(uint64).max) returns (bytes[] memory signers) {
            keys = signers;
        } catch {
            revert NotAStaffAccount(account);
        }
        for (uint256 i = 0; i < keys.length; ++i) {
            if (governanceAccount.isSigner(keys[i])) revert GovernanceSigner(account);
        }
    }

    function _mayPropose(address maker, uint64 role) private view returns (bool) {
        if (role == Roles.ATM) return _holds(Roles.IT_SECURITY, maker);
        return
            Roles.isBranchRole(role) &&
            Roles.branchRole(role) != Roles.BRANCH_MANAGER &&
            _holds(Roles.atBranch(Roles.branchOf(role), Roles.BRANCH_MANAGER), maker);
    }

    function _administers(uint64 role) private pure returns (bool) {
        return Roles.isStaffRole(role) || role == Roles.ATM || role == Roles.SCHEDULER;
    }

    function _proposal(uint256 id) private view returns (Proposal memory p) {
        p = _proposals[id];
        if (p.maker == address(0)) revert NoSuchProposal(id);
    }

    function _holds(uint64 role, address account) private view returns (bool member) {
        (member, ) = manager.hasRole(role, account);
    }
}
