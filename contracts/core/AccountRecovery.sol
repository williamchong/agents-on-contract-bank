// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {MultiSignerAccount} from "./MultiSignerAccount.sol";
import {Roles} from "./Roles.sol";

/// @dev The recovery module, fixed in every customer account at deployment: the one contract besides the
/// account itself that may change its signers, and it can do nothing else. An account opening officer of
/// the branch, after checking the customer's identity in person, proposes the signers to remove and the
/// device or card to enrol, with the hash of the identity check's record; a supervisor of the branch,
/// someone else, approves, and the signer list changes at once. The address, the balance and the history
/// stay. Support may remove a device or card at once, removal only. The officer and approver of a
/// recovery are recorded against the account, so the branch approval ladder can refuse them as the teller
/// or an approver of that customer's operations, for good. A proposal must be approved within a day of the
/// identity check it rests on. Who may call is decided here, not by the access manager, because it depends
/// on the branch. See open question 21 in docs/plan.md.
contract AccountRecovery {
    struct Proposal {
        address officer;
        uint64 branch;
        uint48 proposedAt;
        MultiSignerAccount account;
        bytes32 identityCheck;
        bytes[] removed;
        bytes[] added;
    }

    /// @dev How long an identity check stands for a recovery.
    uint256 public constant VALIDITY = 1 days;

    AccessManager public immutable manager;

    uint256 public proposalCount;
    mapping(uint256 id => Proposal) private _proposals;
    /// @dev Staff who recovered an account, as its officer or approver.
    mapping(address account => mapping(address staff => bool)) public involved;

    event RecoveryProposed(uint256 indexed id, address indexed account, address indexed officer, uint64 branch, bytes32 identityCheck);
    event RecoveryCancelled(uint256 indexed id);
    /// @dev The customer is told through every contact the bank holds.
    event AccountRecovered(uint256 indexed id, address indexed account, address officer, address approver, bytes32 identityCheck);
    event DeviceRemoved(address indexed account, address indexed by, bytes signer);

    error NotOfficer(address caller, uint64 branch);
    error NotSupervisor(address caller, uint64 branch);
    error NotSupport(address caller);
    error ApproverIsOfficer(address approver);
    error NoSuchProposal(uint256 id);
    error NotItsOfficer(address caller, uint256 id);
    error NoIdentityCheck();
    error NotRecoverable(address account);
    error Expired(uint256 id);

    constructor(AccessManager manager_) {
        manager = manager_;
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    /// @dev An account opening officer of `branch` proposes replacing the account's signers, after an
    /// in-person identity check whose record's hash is `identityCheck`.
    function propose(
        MultiSignerAccount account,
        uint64 branch,
        bytes[] calldata removed,
        bytes[] calldata added,
        bytes32 identityCheck
    ) external returns (uint256 id) {
        if (!_has(Roles.atBranch(branch, Roles.ACCOUNT_OPENING_OFFICER), msg.sender)) revert NotOfficer(msg.sender, branch);
        if (identityCheck == 0) revert NoIdentityCheck();
        if (account.recovery() != address(this)) revert NotRecoverable(address(account));
        id = ++proposalCount;
        _proposals[id] = Proposal(msg.sender, branch, uint48(block.timestamp), account, identityCheck, removed, added);
        emit RecoveryProposed(id, address(account), msg.sender, branch, identityCheck);
    }

    /// @dev A supervisor of the branch, other than the officer, approves, and the signers change at once,
    /// while the officer still holds the role.
    function approve(uint256 id) external {
        Proposal memory p = _proposals[id];
        if (p.officer == address(0)) revert NoSuchProposal(id);
        if (block.timestamp > p.proposedAt + VALIDITY) revert Expired(id);
        if (msg.sender == p.officer) revert ApproverIsOfficer(msg.sender);
        if (!_has(Roles.atBranch(p.branch, Roles.SUPERVISOR), msg.sender)) revert NotSupervisor(msg.sender, p.branch);
        if (!_has(Roles.atBranch(p.branch, Roles.ACCOUNT_OPENING_OFFICER), p.officer)) revert NotOfficer(p.officer, p.branch);
        delete _proposals[id];
        address account = address(p.account);
        involved[account][p.officer] = true;
        involved[account][msg.sender] = true;
        p.account.recoverSigners(p.removed, p.added);
        emit AccountRecovered(id, account, p.officer, msg.sender, p.identityCheck);
    }

    function cancel(uint256 id) external {
        if (_proposals[id].officer != msg.sender) revert NotItsOfficer(msg.sender, id);
        delete _proposals[id];
        emit RecoveryCancelled(id);
    }

    /// @dev Support removes a lost device or card at once on the customer's call, removal only.
    function removeLostDevice(MultiSignerAccount account, bytes calldata signer) external {
        if (!_has(Roles.SUPPORT, msg.sender)) revert NotSupport(msg.sender);
        bytes[] memory removed = new bytes[](1);
        removed[0] = signer;
        account.recoverSigners(removed, new bytes[](0));
        emit DeviceRemoved(address(account), msg.sender, signer);
    }

    function _has(uint64 role, address account) private view returns (bool member) {
        (member, ) = manager.hasRole(role, account);
    }
}
