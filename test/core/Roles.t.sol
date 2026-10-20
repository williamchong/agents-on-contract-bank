// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {PartnerKeys} from "../../contracts/core/PartnerKeys.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {Attestations} from "../../contracts/core/Attestations.sol";
import {CashOperations} from "../../contracts/core/CashOperations.sol";
import {BranchApprovals} from "../../contracts/core/BranchApprovals.sol";
import {AssistedOperations} from "../../contracts/core/AssistedOperations.sol";
import {CustomerLimits} from "../../contracts/core/CustomerLimits.sol";
import {IncidentLog} from "../../contracts/core/IncidentLog.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks every restricted function is wired to the role docs/roles.md gives it, and that
/// anyone without that role is refused. The expected roles are written out here, apart from the
/// fixture's wiring, so a change to either that the other does not share fails. Also checks who
/// administers each role: the staff roles module every staff and machine role, governance the rest.
contract RolesTest is BankFixture {
    struct Wire {
        address target;
        bytes call;
        uint64 role;
    }

    address stranger = makeAddr("stranger");

    function test_EachFunctionWiredToItsRole() public view {
        Wire[] memory wires = _expected();
        for (uint256 i = 0; i < wires.length; ++i) {
            assertEq(
                manager.getTargetFunctionRole(wires[i].target, bytes4(wires[i].call)),
                wires[i].role,
                vm.toString(bytes4(wires[i].call))
            );
        }
    }

    function test_EachFunctionRefusesWithoutItsRole() public {
        Wire[] memory wires = _expected();
        for (uint256 i = 0; i < wires.length; ++i) {
            vm.prank(stranger);
            (bool ok, bytes memory reason) = wires[i].target.call(wires[i].call);
            assertFalse(ok, vm.toString(bytes4(wires[i].call)));
            assertEq(reason, abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        }
    }

    function test_OnlyTheLedgerCreatesMoney() public view {
        (bool isLedger, ) = manager.hasRole(Roles.LEDGER, address(ledger));
        assertTrue(isLedger);
        (bool isGovernance, ) = manager.hasRole(Roles.LEDGER, address(this));
        assertFalse(isGovernance);
    }

    /// @dev Only the modules docs/roles.md names may move money without the holder's signature.
    function test_OnlyTheNamedModulesForceTransfers() public view {
        (bool isAssisted, ) = manager.hasRole(Roles.ENFORCER, address(assisted));
        (bool isCash, ) = manager.hasRole(Roles.ENFORCER, address(cash));
        (bool isGovernance, ) = manager.hasRole(Roles.ENFORCER, governance);
        (bool isPayments, ) = manager.hasRole(Roles.ENFORCER, address(payments));
        assertTrue(isAssisted);
        assertTrue(isCash);
        assertFalse(isGovernance);
        assertFalse(isPayments);
    }

    function test_StaffAndMachineRoles_AdministeredByTheModule() public view {
        uint64[21] memory staff = [
            uint64(2), 3, 4, 5, 6, 7, 8, 9, 10, 20, 21,
            101, 102, 103, 104, 105, 201, 202, 203, 204, 205
        ];
        for (uint256 i = 0; i < staff.length; ++i) {
            assertEq(manager.getRoleAdmin(staff[i]), Roles.STAFF_ADMIN, vm.toString(staff[i]));
        }
        (bool isModule, ) = manager.hasRole(Roles.STAFF_ADMIN, address(staffRoles));
        (bool isGovernance, ) = manager.hasRole(Roles.STAFF_ADMIN, governance);
        assertTrue(isModule);
        assertFalse(isGovernance);
    }

    function test_GovernanceAndContractRoles_AdministeredByGovernance() public view {
        uint64[10] memory governed = [uint64(1), 30, 31, 32, 33, 34, 35, 36, 37, 38];
        for (uint256 i = 0; i < governed.length; ++i) {
            assertEq(manager.getRoleAdmin(governed[i]), Roles.ADMIN, vm.toString(governed[i]));
        }
    }

    function test_GovernanceGrantsStaffOnlyThroughTheModule() public {
        address teller = makeAddr("teller");
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManager.AccessManagerUnauthorizedAccount.selector, governance, Roles.STAFF_ADMIN)
        );
        manager.grantRole(Roles.atBranch(1, Roles.TELLER), teller, 0);
    }

    function test_BranchRoles_ScopedInTheNumber() public pure {
        assertEq(Roles.atBranch(1, Roles.TELLER), 101);
        assertEq(Roles.atBranch(2, Roles.TELLER), 201);
        assertEq(Roles.atBranch(1, Roles.ACCOUNT_OPENING_OFFICER), 105);
    }

    function test_BranchRoles_NoBranchZero() public {
        vm.expectRevert(abi.encodeWithSelector(Roles.InvalidBranchRole.selector, 0, Roles.TELLER));
        this.atBranch(0, Roles.TELLER);
    }

    function test_BranchRoles_OnlyTheFive() public {
        vm.expectRevert(abi.encodeWithSelector(Roles.InvalidBranchRole.selector, 1, 6));
        this.atBranch(1, 6);
    }

    /// @dev External, so that the library's revert is caught at the call's depth.
    function atBranch(uint64 branch, uint64 role) external pure returns (uint64) {
        return Roles.atBranch(branch, role);
    }

    /// @dev From the access manager roles table and the permission matrix in docs/roles.md. Admitting
    /// to the allow-list stays with the admin until the onboarding module is wired to it.
    function _expected() private view returns (Wire[] memory w) {
        GeneralLedger.Line[] memory none = new GeneralLedger.Line[](0);
        BranchApprovals.CardAuthorisation memory card;
        w = new Wire[](34);
        w[0] = Wire(address(token), abi.encodeCall(DepositToken.mint, (alice, 1)), Roles.LEDGER);
        w[1] = Wire(address(token), abi.encodeCall(DepositToken.burn, (alice, 1)), Roles.LEDGER);
        w[2] = Wire(address(token), abi.encodeCall(DepositToken.forcedTransfer, (alice, bob, 1)), Roles.ENFORCER);
        w[3] = Wire(address(token), abi.encodeCall(DepositToken.setFrozenTokens, (alice, 1)), Roles.FREEZER);
        w[4] = Wire(address(token), abi.encodeCall(DepositToken.blockUser, (alice)), Roles.COMPLIANCE);
        w[5] = Wire(address(token), abi.encodeCall(DepositToken.unblockUser, (alice)), Roles.GOVERNANCE);
        w[6] = Wire(address(token), abi.encodeCall(DepositToken.allowUser, (stranger)), Roles.ADMIN);
        w[7] = Wire(address(ledger), abi.encodeCall(GeneralLedger.post, (none, "")), Roles.BOOKKEEPER);
        w[8] = Wire(address(ledger), abi.encodeCall(GeneralLedger.postWithMint, (alice, 1, none, "")), Roles.BOOKKEEPER);
        w[9] = Wire(address(ledger), abi.encodeCall(GeneralLedger.postWithBurn, (alice, 1, none, "")), Roles.BOOKKEEPER);
        w[10] = Wire(
            address(ledger),
            abi.encodeCall(GeneralLedger.postOpening, (new address[](0), new uint256[](0), none, "")),
            Roles.GOVERNANCE
        );
        w[11] = Wire(address(partnerKeys), abi.encodeCall(PartnerKeys.setKey, (bytes32(0), "")), Roles.GOVERNANCE);
        w[12] = Wire(address(partnerKeys), abi.encodeCall(PartnerKeys.revokeKey, (bytes32(0))), Roles.IT_SECURITY);
        w[13] = Wire(address(payments), abi.encodeCall(Payments.clearIncoming, (bytes32(0))), Roles.COMPLIANCE);
        w[14] = Wire(address(payments), abi.encodeCall(Payments.returnIncoming, (bytes32(0))), Roles.COMPLIANCE);
        w[15] = Wire(address(payments), abi.encodeCall(Payments.clearOutgoing, (bytes32(0))), Roles.COMPLIANCE);
        w[16] = Wire(address(payments), abi.encodeCall(Payments.returnOutgoing, (bytes32(0))), Roles.COMPLIANCE);
        w[17] = Wire(address(payments), abi.encodeCall(Payments.setScreeningThreshold, (0)), Roles.GOVERNANCE);
        w[18] = Wire(address(attestations), abi.encodeCall(Attestations.setMaxAge, (0)), Roles.GOVERNANCE);
        w[19] = Wire(
            address(cash),
            abi.encodeCall(CashOperations.openCash, (new CashOperations.Location[](0), new uint256[](0))),
            Roles.GOVERNANCE
        );
        w[20] = Wire(address(cash), abi.encodeCall(CashOperations.setLimits, (CashOperations.Limits(0, 0, 0, 0))), Roles.GOVERNANCE);
        w[21] = Wire(address(cash), abi.encodeCall(CashOperations.withdrawAtAtm, (1, card)), Roles.ATM);
        w[22] = Wire(address(cash), abi.encodeCall(CashOperations.confirmDispense, (bytes32(0))), Roles.ATM);
        w[23] = Wire(address(cash), abi.encodeCall(CashOperations.reportFailure, (bytes32(0))), Roles.ATM);
        w[24] = Wire(address(cash), abi.encodeCall(BranchApprovals.setLadder, (BranchApprovals.Ladder(0, 0))), Roles.GOVERNANCE);
        w[25] = Wire(address(assisted), abi.encodeCall(BranchApprovals.setLadder, (BranchApprovals.Ladder(0, 0))), Roles.GOVERNANCE);
        w[26] = Wire(address(limits), abi.encodeCall(CustomerLimits.countMovement, (alice, bob, 1)), Roles.LIMIT_KEEPER);
        w[27] = Wire(address(limits), abi.encodeCall(CustomerLimits.countPayment, (alice, bytes32(0), 1)), Roles.LIMIT_KEEPER);
        w[28] = Wire(address(limits), abi.encodeCall(CustomerLimits.enrol, (alice)), Roles.GOVERNANCE);
        w[29] = Wire(address(limits), abi.encodeCall(CustomerLimits.setChannel, (alice, CustomerLimits.Channel.Own)), Roles.GOVERNANCE);
        w[30] = Wire(address(limits), abi.encodeCall(CustomerLimits.setLimits, (CustomerLimits.Limits(0, 0, 0))), Roles.GOVERNANCE);
        w[31] = Wire(address(incidents), abi.encodeCall(IncidentLog.report, (bytes32(0), bytes32(0), bytes32(0))), Roles.FINANCE);
        w[32] = Wire(address(limits), abi.encodeCall(CustomerLimits.releasePayment, (alice, 1, 0, false, false)), Roles.LIMIT_KEEPER);
        w[33] = Wire(address(payments), abi.encodeCall(Payments.payFor, (alice, 1, bytes32(0))), Roles.PAYMENT_ORIGINATOR);
    }
}
