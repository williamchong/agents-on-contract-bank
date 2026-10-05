// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks every restricted function is wired to the role docs/roles.md gives it, and that
/// anyone without that role is refused. The expected roles are written out here, apart from the
/// fixture's wiring, so a change to either that the other does not share fails.
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
        w = new Wire[](11);
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
    }
}
