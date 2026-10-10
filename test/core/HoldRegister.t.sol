// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {HoldRegister} from "../../contracts/core/HoldRegister.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the hold register against the freeze and unfreeze rows of the permission matrix and
/// the hold register notes in docs/roles.md: who places and lifts a hold, and that an account's
/// frozen amount is always the sum of its open holds.
contract HoldRegisterTest is BankFixture {
    uint64 immutable SUPERVISOR_1 = Roles.atBranch(1, Roles.SUPERVISOR);
    uint64 immutable SUPERVISOR_2 = Roles.atBranch(2, Roles.SUPERVISOR);
    uint64 immutable TELLER_2 = Roles.atBranch(2, Roles.TELLER);

    address support;
    address compliance;
    address supervisor1;
    address supervisor2;
    address redTeam;
    address enforcer = makeAddr("enforcer");
    address carol = makeAddr("carol");

    HoldHandler handler;

    function setUp() public override {
        super.setUp();
        support = _staff("support");
        compliance = _staff("compliance");
        supervisor1 = _staff("supervisor1");
        supervisor2 = _staff("supervisor2");
        redTeam = _staff("redTeam");
        _grantStaff(support, Roles.SUPPORT);
        _grantStaff(compliance, Roles.COMPLIANCE);
        // Branch roles are granted by the branch manager with IT security's approval; that path is
        // checked in StaffRolesTest, so they are granted directly here.
        vm.startPrank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, supervisor1, 0);
        manager.grantRole(SUPERVISOR_2, supervisor2, 0);
        manager.grantRole(TELLER_2, redTeam, 0);
        vm.stopPrank();
        vm.prank(governance);
        manager.grantRole(Roles.ENFORCER, enforcer, 0);

        handler = new HoldHandler(holds, compliance, alice, bob);
        targetContract(address(handler));
    }

    /// @dev Over any run of placing and lifting, each account's frozen amount is the sum of its
    /// open holds, and the books still balance.
    function invariant_FrozenIsSumOfOpenHolds() public view {
        address[2] memory accounts = [alice, bob];
        for (uint256 i = 0; i < accounts.length; ++i) {
            uint256[] memory ids = holds.holdsOf(accounts[i]);
            uint256 sum;
            for (uint256 j = 0; j < ids.length; ++j) sum += holds.hold(ids[j]).amount;
            assertEq(holds.heldOf(accounts[i]), sum, "register total is its open holds");
            assertEq(token.frozen(accounts[i]), sum, "token freezes the register total");
        }
        _assertBooksBalance();
    }

    // Placing

    function test_Place_BySupportComplianceAndSupervisor() public {
        _place(support, Roles.SUPPORT, 100);
        _place(compliance, Roles.COMPLIANCE, 200);
        _place(supervisor1, SUPERVISOR_1, 300);
        assertEq(token.frozen(alice), 600);
        assertEq(holds.holdsOf(alice).length, 3);
    }

    function test_Place_RecordsTheHold() public {
        vm.expectEmit(address(holds));
        emit HoldRegister.Placed(1, alice, Roles.COMPLIANCE, 500, compliance, "screening");
        uint256 id = _place(compliance, Roles.COMPLIANCE, 500);
        HoldRegister.Hold memory h = holds.hold(id);
        assertEq(h.account, alice);
        assertEq(h.amount, 500);
        assertEq(h.role, Roles.COMPLIANCE);
        assertEq(h.placer, compliance);
        assertEq(holds.heldOf(alice), 500);
        assertEq(token.frozen(alice), 500);
        assertEq(holds.holdsOf(alice)[0], id);
    }

    /// @dev Until accounts record their home branch, a supervisor of any branch may place.
    function test_Place_BySupervisorOfAnyBranch() public {
        _place(supervisor2, SUPERVISOR_2, 100);
        assertEq(token.frozen(alice), 100);
    }

    function test_Place_RefusesOtherRoles() public {
        vm.prank(redTeam);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotPlacer.selector, redTeam, TELLER_2));
        holds.place(alice, 100, TELLER_2, "");

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotPlacer.selector, governance, Roles.GOVERNANCE));
        holds.place(alice, 100, Roles.GOVERNANCE, "");
    }

    function test_Place_RefusesARoleNotHeld() public {
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotPlacer.selector, support, Roles.COMPLIANCE));
        holds.place(alice, 100, Roles.COMPLIANCE, "");

        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotPlacer.selector, supervisor1, SUPERVISOR_2));
        holds.place(alice, 100, SUPERVISOR_2, "");
    }

    function test_Place_RefusesZero() public {
        vm.prank(support);
        vm.expectRevert(HoldRegister.ZeroAmount.selector);
        holds.place(alice, 0, Roles.SUPPORT, "");
    }

    function test_Place_RefusesAccountNotAdmitted() public {
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(DepositToken.NotAdmitted.selector, carol));
        holds.place(carol, 100, Roles.SUPPORT, "");
    }

    function test_Place_OnBlockedAccount() public {
        vm.prank(compliance);
        token.blockUser(alice);
        _place(compliance, Roles.COMPLIANCE, 100);
        assertEq(token.frozen(alice), 100);
    }

    /// @dev Only the register sets frozen amounts, so no one can set one beside it.
    function test_SetFrozenTokens_OnlyByRegister() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, compliance));
        token.setFrozenTokens(alice, 100);
    }

    // What a hold does

    function test_Hold_StopsSpendingHeldMoney() public {
        uint256 balance = token.balanceOf(alice);
        _place(compliance, Roles.COMPLIANCE, 300);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, alice, balance, balance - 300)
        );
        token.transfer(bob, balance);

        vm.prank(alice);
        token.transfer(bob, balance - 300);
        assertEq(token.balanceOf(alice), 300);
    }

    /// @dev A hold beyond the balance freezes money as it arrives, as a flagged payment in is.
    function test_Hold_BeyondBalanceFreezesMoneyStillToArrive() public {
        uint256 balance = token.balanceOf(alice);
        _place(compliance, Roles.COMPLIANCE, balance + 500);
        vm.prank(bob);
        token.transfer(alice, 500);
        assertEq(token.frozen(alice), balance + 500);
        assertEq(token.available(alice), 0);
    }

    /// @dev A forced transfer within the unfrozen balance leaves the freeze where it was.
    function test_Hold_ForcedTransferOfUnfrozenMoneyKeepsFreeze() public {
        uint256 balance = token.balanceOf(alice);
        _place(compliance, Roles.COMPLIANCE, 300);
        vm.prank(enforcer);
        token.forcedTransfer(alice, pending, balance - 300);
        assertEq(token.frozen(alice), 300);
        assertEq(holds.heldOf(alice), 300);
    }

    // Lifting

    function test_Lift_LeavesOtherHolds() public {
        uint256 first = _place(support, Roles.SUPPORT, 100);
        _place(compliance, Roles.COMPLIANCE, 200);
        vm.expectEmit(address(holds));
        emit HoldRegister.Lifted(first, alice, supervisor1);
        vm.prank(supervisor1);
        holds.lift(first, SUPERVISOR_1);
        assertEq(token.frozen(alice), 200);
        assertEq(holds.heldOf(alice), 200);
        assertEq(holds.holdsOf(alice).length, 1);
        assertEq(holds.hold(first).placer, address(0));
    }

    function test_Lift_ComplianceLiftsAnyHold() public {
        uint256[3] memory ids = [
            _place(support, Roles.SUPPORT, 100),
            _place(supervisor1, SUPERVISOR_1, 200),
            _place(compliance, Roles.COMPLIANCE, 300)
        ];
        for (uint256 i = 0; i < ids.length; ++i) {
            vm.prank(compliance);
            holds.lift(ids[i], Roles.COMPLIANCE);
        }
        assertEq(token.frozen(alice), 0);
    }

    function test_Lift_SupervisorOfAnyBranch() public {
        uint256 id = _place(supervisor1, SUPERVISOR_1, 100);
        vm.prank(supervisor2);
        holds.lift(id, SUPERVISOR_2);
        assertEq(token.frozen(alice), 0);
    }

    /// @dev A flagged payment waits for compliance, not for the branch the customer complains to.
    function test_Lift_SupervisorCannotLiftComplianceHold() public {
        uint256 id = _place(compliance, Roles.COMPLIANCE, 100);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotLifter.selector, supervisor1, SUPERVISOR_1, id));
        holds.lift(id, SUPERVISOR_1);
    }

    function test_Lift_SupportCannotLift() public {
        uint256 id = _place(support, Roles.SUPPORT, 100);
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotLifter.selector, support, Roles.SUPPORT, id));
        holds.lift(id, Roles.SUPPORT);
    }

    function test_Lift_RefusesARoleNotHeld() public {
        uint256 id = _place(support, Roles.SUPPORT, 100);
        vm.prank(redTeam);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotLifter.selector, redTeam, SUPERVISOR_2, id));
        holds.lift(id, SUPERVISOR_2);
    }

    function test_Lift_RefusesUnknownOrLiftedHold() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NoSuchHold.selector, 1));
        holds.lift(1, Roles.COMPLIANCE);

        uint256 id = _place(support, Roles.SUPPORT, 100);
        vm.prank(compliance);
        holds.lift(id, Roles.COMPLIANCE);
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NoSuchHold.selector, id));
        holds.lift(id, Roles.COMPLIANCE);
    }

    function _place(address by, uint64 asRole, uint256 amount) private returns (uint256) {
        vm.prank(by);
        return holds.place(alice, amount, asRole, "screening");
    }
}

/// @dev Places and lifts holds on two customers as compliance, in any order.
contract HoldHandler is Test {
    HoldRegister immutable holds;
    address immutable compliance;
    address[2] customers;

    constructor(HoldRegister holds_, address compliance_, address alice, address bob) {
        holds = holds_;
        compliance = compliance_;
        customers = [alice, bob];
    }

    function place(bool second, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        vm.prank(compliance);
        holds.place(customers[second ? 1 : 0], amount, Roles.COMPLIANCE, "");
    }

    function lift(bool second, uint256 index) external {
        uint256[] memory ids = holds.holdsOf(customers[second ? 1 : 0]);
        if (ids.length == 0) return;
        vm.prank(compliance);
        holds.lift(ids[bound(index, 0, ids.length - 1)], Roles.COMPLIANCE);
    }
}
