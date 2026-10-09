// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {StaffRoles} from "../../contracts/core/StaffRoles.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the staff roles module against the grant and revoke rows of the permission matrix
/// and the conflicting pairs in docs/roles.md.
contract StaffRolesTest is BankFixture {
    uint64 immutable TELLER_1 = Roles.atBranch(1, Roles.TELLER);
    uint64 immutable SUPERVISOR_1 = Roles.atBranch(1, Roles.SUPERVISOR);
    uint64 immutable MANAGER_1 = Roles.atBranch(1, Roles.BRANCH_MANAGER);
    uint64 immutable TELLER_2 = Roles.atBranch(2, Roles.TELLER);
    uint64 immutable MANAGER_2 = Roles.atBranch(2, Roles.BRANCH_MANAGER);

    address itSecurity;
    address risk;
    address manager1;
    address manager2;
    address supervisor1;
    address atm = makeAddr("atm");

    function setUp() public override {
        super.setUp();
        itSecurity = _staff("itSecurity");
        risk = _staff("risk");
        manager1 = _staff("manager1");
        manager2 = _staff("manager2");
        supervisor1 = _staff("supervisor1");
        _grantStaff(itSecurity, Roles.IT_SECURITY);
        _grantStaff(risk, Roles.RISK);
        _grantStaff(manager1, MANAGER_1);
        _grantStaff(manager2, MANAGER_2);
        _branchGrant(manager1, supervisor1, SUPERVISOR_1);
    }

    // Governance's grants

    function test_Governance_GrantsControlRolesAtOnce() public {
        address treasurer = _staff("treasurer");
        _grantStaff(treasurer, Roles.TREASURY);
        assertTrue(_holds(Roles.TREASURY, treasurer));
    }

    function test_Governance_GrantsThroughItsTimeLock() public {
        address auditor = _staff("auditor");
        _govern(address(staffRoles), abi.encodeCall(StaffRoles.grant, (auditor, Roles.INTERNAL_AUDIT)));
        assertTrue(_holds(Roles.INTERNAL_AUDIT, auditor));
    }

    function test_Governance_DoesNotGrantBranchStaff() public {
        address teller = _staff("teller");
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, governance, TELLER_1));
        staffRoles.grant(teller, TELLER_1);
    }

    function test_OnlyGovernanceGrantsItsRoles() public {
        address treasurer = _staff("treasurer");
        vm.prank(risk);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, risk, Roles.TREASURY));
        staffRoles.grant(treasurer, Roles.TREASURY);
    }

    function test_ContractRolesNotGrantedHere() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, governance, Roles.LEDGER));
        staffRoles.grant(address(ledger), Roles.LEDGER);
    }

    // Branch grants

    function test_BranchGrant_WaitsForITSecurity() public {
        address teller = _staff("teller");
        vm.prank(manager1);
        uint256 id = staffRoles.propose(teller, TELLER_1, true);
        assertFalse(_holds(TELLER_1, teller));

        vm.expectEmit(address(staffRoles));
        emit StaffRoles.Granted(teller, TELLER_1, manager1, itSecurity);
        vm.prank(itSecurity);
        staffRoles.approve(id, Roles.IT_SECURITY);
        assertTrue(_holds(TELLER_1, teller));
    }

    function test_BranchGrant_OnlyOwnBranch() public {
        address teller = _staff("teller");
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, manager1, TELLER_2));
        staffRoles.propose(teller, TELLER_2, true);
    }

    function test_BranchGrant_NotTheBranchManagerRole() public {
        address deputy = _staff("deputy");
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, manager1, MANAGER_1));
        staffRoles.propose(deputy, MANAGER_1, true);
    }

    function test_BranchGrant_ApprovedOnlyByITSecurity() public {
        address teller = _staff("teller");
        vm.prank(manager1);
        uint256 id = staffRoles.propose(teller, TELLER_1, true);

        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotApprover.selector, supervisor1, SUPERVISOR_1));
        staffRoles.approve(id, SUPERVISOR_1);

        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotApprover.selector, supervisor1, Roles.IT_SECURITY));
        staffRoles.approve(id, Roles.IT_SECURITY);
    }

    function test_BranchGrant_MakerLosesRoleBeforeApproval() public {
        address teller = _staff("teller");
        vm.prank(manager1);
        uint256 id = staffRoles.propose(teller, TELLER_1, true);
        vm.prank(risk);
        staffRoles.revoke(manager1, MANAGER_1);

        vm.prank(itSecurity);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, manager1, TELLER_1));
        staffRoles.approve(id, Roles.IT_SECURITY);
    }

    function test_BranchGrant_ConflictArisingBeforeApproval() public {
        address auditor = _staff("auditor");
        vm.prank(manager1);
        uint256 id = staffRoles.propose(auditor, TELLER_1, true);
        _grantStaff(auditor, Roles.INTERNAL_AUDIT);

        vm.prank(itSecurity);
        vm.expectRevert(
            abi.encodeWithSelector(StaffRoles.ConflictingRoles.selector, auditor, Roles.INTERNAL_AUDIT, TELLER_1)
        );
        staffRoles.approve(id, Roles.IT_SECURITY);
    }

    function test_Cancel_OnlyByTheMaker() public {
        address teller = _staff("teller");
        vm.prank(manager1);
        uint256 id = staffRoles.propose(teller, TELLER_1, true);

        vm.prank(itSecurity);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotMaker.selector, itSecurity, id));
        staffRoles.cancel(id);

        vm.prank(manager1);
        staffRoles.cancel(id);
        vm.prank(itSecurity);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NoSuchProposal.selector, id));
        staffRoles.approve(id, Roles.IT_SECURITY);
    }

    // No one grants to themselves

    function test_SelfGrant_ByTheMakerRefused() public {
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.SelfGrant.selector, manager1));
        staffRoles.propose(manager1, TELLER_1, true);
    }

    function test_SelfGrant_ByTheApproverRefused() public {
        vm.prank(itSecurity);
        uint256 id = staffRoles.propose(supervisor1, Roles.ATM, true);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.SelfGrant.selector, supervisor1));
        staffRoles.approve(id, SUPERVISOR_1);
    }

    // Governance signers

    function test_GovernanceSigner_RefusedAStaffRole() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = officerKeys[2];
        address[] memory verifiers = new address[](1);
        verifiers[0] = address(p256);
        address officer = address(new MultiSignerAccount(verifiers, _signers(keys), 1));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.GovernanceSigner.selector, officer));
        staffRoles.grant(officer, Roles.RISK);
    }

    function test_GovernanceAccountItselfRefused() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.GovernanceSigner.selector, address(officers)));
        staffRoles.grant(address(officers), Roles.RISK);
    }

    function test_StaffRoleOnlyToAStaffAccount() public {
        address plain = makeAddr("plain");
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotAStaffAccount.selector, plain));
        staffRoles.grant(plain, Roles.RISK);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotAStaffAccount.selector, address(token)));
        staffRoles.grant(address(token), Roles.RISK);
    }

    // Conflicting pairs

    function test_ConflictingPairs_RefusedInEitherOrder() public {
        uint64[2][6] memory pairs = [
            [Roles.TREASURY, Roles.FINANCE],
            [Roles.FINANCE, Roles.TREASURY],
            [Roles.IT_SECURITY, Roles.BACK_OFFICE],
            [Roles.SUPPORT, Roles.IT_SECURITY],
            [Roles.INTERNAL_AUDIT, Roles.CREDIT_OFFICER],
            [Roles.COMPLIANCE, Roles.INTERNAL_AUDIT]
        ];
        for (uint256 i = 0; i < pairs.length; ++i) {
            address account = _staff(string.concat("pair", vm.toString(i)));
            _grantStaff(account, pairs[i][0]);
            vm.prank(governance);
            vm.expectRevert(
                abi.encodeWithSelector(StaffRoles.ConflictingRoles.selector, account, pairs[i][0], pairs[i][1])
            );
            staffRoles.grant(account, pairs[i][1]);
        }
    }

    function test_ConflictingPairs_ITSecurityAndBranchRoles() public {
        vm.prank(manager1);
        vm.expectRevert(
            abi.encodeWithSelector(StaffRoles.ConflictingRoles.selector, itSecurity, Roles.IT_SECURITY, TELLER_1)
        );
        staffRoles.propose(itSecurity, TELLER_1, true);

        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(StaffRoles.ConflictingRoles.selector, manager1, MANAGER_1, Roles.IT_SECURITY)
        );
        staffRoles.grant(manager1, Roles.IT_SECURITY);
    }

    function test_RolesThatDoNotConflictCombine() public {
        address officer = _staff("officer");
        _grantStaff(officer, Roles.COMPLIANCE);
        _grantStaff(officer, Roles.SUPPORT);
        assertTrue(_holds(Roles.COMPLIANCE, officer) && _holds(Roles.SUPPORT, officer));
    }

    function test_RenouncedRoleNoLongerConflicts() public {
        address treasurer = _staff("treasurer");
        _grantStaff(treasurer, Roles.TREASURY);
        vm.prank(treasurer);
        manager.renounceRole(Roles.TREASURY, treasurer);
        _grantStaff(treasurer, Roles.FINANCE);
        assertTrue(_holds(Roles.FINANCE, treasurer));
    }

    // Revoking

    function test_Revoke_AtOnceByTheBranchManager() public {
        address teller = _branchGrant(manager1, _staff("teller"), TELLER_1);
        vm.prank(manager1);
        staffRoles.revoke(teller, TELLER_1);
        assertFalse(_holds(TELLER_1, teller));
    }

    function test_Revoke_BranchManagerOnlyOwnBranch() public {
        address teller = _branchGrant(manager1, _staff("teller"), TELLER_1);
        vm.prank(manager2);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotRevoker.selector, manager2, TELLER_1));
        staffRoles.revoke(teller, TELLER_1);
    }

    function test_Revoke_BranchManagerNotAnotherBranchManager() public {
        address deputy = _staff("deputy");
        _grantStaff(deputy, MANAGER_1);
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotRevoker.selector, manager1, MANAGER_1));
        staffRoles.revoke(deputy, MANAGER_1);
    }

    function test_Revoke_RiskAndGovernanceAnyStaffRole() public {
        address teller = _branchGrant(manager1, _staff("teller"), TELLER_1);
        vm.prank(risk);
        staffRoles.revoke(teller, TELLER_1);
        vm.prank(governance);
        staffRoles.revoke(manager1, MANAGER_1);
        assertFalse(_holds(TELLER_1, teller) || _holds(MANAGER_1, manager1));
    }

    function test_Revoke_NotByAnyoneElse() public {
        vm.prank(itSecurity);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotRevoker.selector, itSecurity, Roles.RISK));
        staffRoles.revoke(risk, Roles.RISK);
    }

    function test_Revoke_ContractRolesNotAdministered() public {
        vm.prank(risk);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotAdministered.selector, Roles.LEDGER));
        staffRoles.revoke(address(ledger), Roles.LEDGER);
    }

    // ATMs

    function test_ATM_EnrolledWithASupervisor() public {
        vm.prank(itSecurity);
        uint256 id = staffRoles.propose(atm, Roles.ATM, true);
        vm.prank(supervisor1);
        staffRoles.approve(id, SUPERVISOR_1);
        assertTrue(_holds(Roles.ATM, atm));
    }

    function test_ATM_OnlyITSecurityProposes() public {
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, manager1, Roles.ATM));
        staffRoles.propose(atm, Roles.ATM, true);
    }

    function test_ATM_ApprovedOnlyByASupervisor() public {
        vm.prank(itSecurity);
        uint256 id = staffRoles.propose(atm, Roles.ATM, true);
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotApprover.selector, manager1, MANAGER_1));
        staffRoles.approve(id, MANAGER_1);
    }

    function test_ATM_RetiredWithASupervisor() public {
        _enrolATM();
        vm.prank(itSecurity);
        uint256 id = staffRoles.propose(atm, Roles.ATM, false);
        assertTrue(_holds(Roles.ATM, atm));
        vm.prank(supervisor1);
        staffRoles.approve(id, SUPERVISOR_1);
        assertFalse(_holds(Roles.ATM, atm));
    }

    function test_ATM_CutOffAtOnceByRisk() public {
        _enrolATM();
        vm.prank(risk);
        staffRoles.revoke(atm, Roles.ATM);
        assertFalse(_holds(Roles.ATM, atm));
    }

    function test_OnlyAnATMIsRetiredByProposal() public {
        address teller = _branchGrant(manager1, _staff("teller"), TELLER_1);
        vm.prank(manager1);
        vm.expectRevert(abi.encodeWithSelector(StaffRoles.NotGrantor.selector, manager1, TELLER_1));
        staffRoles.propose(teller, TELLER_1, false);
    }

    // Helpers

    function _branchGrant(address maker, address account, uint64 role) private returns (address) {
        vm.prank(maker);
        uint256 id = staffRoles.propose(account, role, true);
        vm.prank(itSecurity);
        staffRoles.approve(id, Roles.IT_SECURITY);
        return account;
    }

    function _enrolATM() private {
        vm.prank(itSecurity);
        uint256 id = staffRoles.propose(atm, Roles.ATM, true);
        vm.prank(supervisor1);
        staffRoles.approve(id, SUPERVISOR_1);
    }
}
