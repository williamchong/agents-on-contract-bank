// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Roles} from "../../contracts/core/Roles.sol";
import {MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {AccountRecovery} from "../../contracts/core/AccountRecovery.sol";
import {BranchApprovals} from "../../contracts/core/BranchApprovals.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the recovery module against the all devices lost scenario in docs/scenarios.md and the
/// recovery rows of the permission matrix in docs/roles.md: an account opening officer with a different
/// supervisor's approval replaces the signers of an account whose devices and card are all lost, the
/// address and balance stay, support can only remove, and staff who recovered an account cannot then act
/// for that customer at the branch.
contract AccountRecoveryTest is BankFixture {
    uint64 constant TELLER_1 = 101;
    uint64 constant SUPERVISOR_1 = 102;
    uint64 constant OFFICER_1 = 105;
    uint64 constant SUPERVISOR_2 = 202;
    bytes32 constant ID_CHECK = keccak256("record of the in-person identity check");

    address officer;
    address supervisor;
    address supervisor2;
    address support;
    MultiSignerAccount carol;
    uint256 phone = _key("carol's phone");
    uint256 card = _key("carol's card");
    uint256 newPhone = _key("carol's new phone");

    function setUp() public override {
        super.setUp();
        officer = _staff("officer");
        supervisor = _staff("supervisor");
        supervisor2 = _staff("supervisor 2");
        support = _staff("support");
        _grantStaff(support, Roles.SUPPORT);
        vm.startPrank(address(staffRoles));
        manager.grantRole(OFFICER_1, officer, 0);
        manager.grantRole(SUPERVISOR_1, supervisor, 0);
        manager.grantRole(SUPERVISOR_2, supervisor2, 0);
        manager.grantRole(TELLER_1, teller1, 0);
        vm.stopPrank();

        uint256[] memory keys = new uint256[](2);
        keys[0] = phone;
        keys[1] = card;
        carol = new MultiSignerAccount(_verifiers(), _signers(keys), 1, address(recovery));
        vm.prank(governance);
        token.allowUser(address(carol));
        vm.prank(otherCustomers);
        token.transfer(address(carol), 50_000 * HKD);
    }

    /// @dev All devices lost: the old signers are gone and a new one enrolled; the address and balance
    /// are unchanged; no money moved.
    function test_Recover_ReplacesEverySigner() public {
        uint256 balance = token.balanceOf(address(carol));
        uint256 supply = token.totalSupply();
        uint256 id = _propose(officer);

        vm.expectEmit(true, true, false, true, address(recovery));
        emit AccountRecovery.AccountRecovered(id, address(carol), officer, supervisor, ID_CHECK);
        vm.prank(supervisor);
        recovery.approve(id);

        assertFalse(carol.isSigner(_signer(phone)));
        assertFalse(carol.isSigner(_signer(card)));
        assertTrue(carol.isSigner(_signer(newPhone)));
        assertEq(token.balanceOf(address(carol)), balance);
        assertEq(token.totalSupply(), supply);
        assertTrue(recovery.involved(address(carol), officer));
        assertTrue(recovery.involved(address(carol), supervisor));
    }

    function test_Recover_OfficerCannotApproveTheirOwn() public {
        vm.prank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, officer, 0);
        uint256 id = _propose(officer);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.ApproverIsOfficer.selector, officer));
        recovery.approve(id);
    }

    function test_Recover_OnlyAnOfficerOfTheBranchProposes() public {
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.NotOfficer.selector, supervisor, 1));
        recovery.propose(carol, 1, _list(phone), _list(newPhone), ID_CHECK);
    }

    function test_Recover_OnlyASupervisorOfTheBranchApproves() public {
        uint256 id = _propose(officer);
        vm.prank(supervisor2);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.NotSupervisor.selector, supervisor2, 1));
        recovery.approve(id);
    }

    function test_Recover_NeedsTheIdentityCheck() public {
        vm.prank(officer);
        vm.expectRevert(AccountRecovery.NoIdentityCheck.selector);
        recovery.propose(carol, 1, _list(phone), _list(newPhone), 0);
    }

    function test_Recover_OnlyAccountsWithTheModuleFixedInThem() public {
        MultiSignerAccount staffAccount = MultiSignerAccount(payable(_staff("someone on staff")));
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.NotRecoverable.selector, address(staffAccount)));
        recovery.propose(staffAccount, 1, _list(phone), _list(newPhone), ID_CHECK);
    }

    function test_Recover_RefusedIfTheOfficerLostTheRole() public {
        uint256 id = _propose(officer);
        vm.prank(address(staffRoles));
        manager.revokeRole(OFFICER_1, officer);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.NotOfficer.selector, officer, 1));
        recovery.approve(id);
    }

    function test_Recover_ExpiresADayAfterTheIdentityCheck() public {
        uint256 id = _propose(officer);
        vm.warp(block.timestamp + recovery.VALIDITY() + 1);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.Expired.selector, id));
        recovery.approve(id);
    }

    function test_Recover_CannotLeaveTheAccountWithNoSigner() public {
        bytes[] memory removed = new bytes[](2);
        removed[0] = _signer(phone);
        removed[1] = _signer(card);
        vm.prank(officer);
        uint256 id = recovery.propose(carol, 1, removed, new bytes[](0), ID_CHECK);
        vm.prank(supervisor);
        vm.expectRevert();
        recovery.approve(id);
        assertTrue(carol.isSigner(_signer(phone)));
    }

    function test_Support_CannotRemoveTheLastSigner() public {
        vm.startPrank(support);
        recovery.removeLostDevice(carol, _signer(phone));
        vm.expectRevert();
        recovery.removeLostDevice(carol, _signer(card));
        vm.stopPrank();
    }

    function test_Ladder_RefusesTheApproverOfARecoveryAtTheCounterToo() public {
        _recover();
        vm.prank(teller1);
        bytes32 ref = cash.withdrawAtCounterOnPaper(1, address(carol), 1_000 * HKD, keccak256("slip"));
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.RecoveredTheAccount.selector, supervisor, address(carol)));
        cash.approve(ref);
    }

    function test_Recover_CancelledByItsOfficer() public {
        uint256 id = _propose(officer);
        vm.prank(officer);
        recovery.cancel(id);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.NoSuchProposal.selector, id));
        recovery.approve(id);
    }

    function test_Account_OnlyTheModuleChangesSignersFromOutside() public {
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(MultiSignerAccount.NotRecovery.selector, officer));
        carol.recoverSigners(_list(phone), _list(newPhone));
    }

    // Support

    function test_Support_RemovesALostDeviceAtOnce() public {
        vm.prank(support);
        recovery.removeLostDevice(carol, _signer(phone));
        assertFalse(carol.isSigner(_signer(phone)));
        assertTrue(carol.isSigner(_signer(card)));
    }

    function test_Support_OnlySupport() public {
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(AccountRecovery.NotSupport.selector, officer));
        recovery.removeLostDevice(carol, _signer(phone));
    }

    // Separation of duties

    function test_Ladder_RefusesTheApproverOfARecovery() public {
        _recover();
        vm.prank(teller1);
        bytes32 ref = assisted.transferOnPaper(1, address(carol), bob, 1_000 * HKD, keccak256("slip"));
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.RecoveredTheAccount.selector, supervisor, address(carol)));
        assisted.approve(ref);
    }

    function test_Ladder_RefusesTheOfficerOfARecoveryAsTeller() public {
        vm.prank(address(staffRoles));
        manager.grantRole(TELLER_1, officer, 0);
        _recover();
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.RecoveredTheAccount.selector, officer, address(carol)));
        assisted.transferOnPaper(1, address(carol), bob, 1_000 * HKD, keccak256("slip"));
    }

    // Helpers

    function _propose(address by) private returns (uint256) {
        bytes[] memory removed = new bytes[](2);
        removed[0] = _signer(phone);
        removed[1] = _signer(card);
        vm.prank(by);
        return recovery.propose(carol, 1, removed, _list(newPhone), ID_CHECK);
    }

    function _recover() private {
        uint256 id = _propose(officer);
        vm.prank(supervisor);
        recovery.approve(id);
    }

    function _list(uint256 key) private view returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = _signer(key);
    }
}
