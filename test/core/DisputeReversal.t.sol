// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {HoldRegister} from "../../contracts/core/HoldRegister.sol";
import {DisputeReversal} from "../../contracts/core/DisputeReversal.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks dispute reversal against the reverse a disputed operation row of the permission matrix in
/// docs/roles.md and the second half of the forged paper slip scenario in docs/scenarios.md: support opens
/// a dispute and the recipient's money is frozen at once, back office proposes and a different compliance
/// officer approves, and the module takes back only what is still in the recipient's account, never cutting
/// into another hold, so the register and the token's frozen amount stay in step.
contract DisputeReversalTest is BankFixture {
    uint64 constant SUPERVISOR_1 = 102;
    uint256 constant AMOUNT = 8_000 * HKD;
    bytes32 constant OPERATION = keccak256("the disputed transfer");

    address support;
    address backOffice;
    address compliance;
    address supervisor;

    function setUp() public override {
        super.setUp();
        support = _staff("support");
        backOffice = _staff("back office");
        compliance = _staff("compliance");
        supervisor = _staff("supervisor");
        _grantStaff(support, Roles.SUPPORT);
        _grantStaff(backOffice, Roles.BACK_OFFICE);
        _grantStaff(compliance, Roles.COMPLIANCE);
        vm.prank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, supervisor, 0);
        // The disputed transfer: Alice's money reached Bob.
        vm.prank(alice);
        token.transfer(bob, AMOUNT);
    }

    function test_Open_FreezesTheRecipientsMoneyAtOnce() public {
        _open();
        assertEq(holds.heldOf(bob), AMOUNT);
        uint256 free = token.balanceOf(bob) - AMOUNT;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, bob, free + 1, free));
        token.transfer(alice, free + 1);
    }

    function test_Reverse_ReturnsTheMoneyAndLiftsItsHold() public {
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 id = _open();
        _propose(id);
        vm.prank(compliance);
        disputes.approve(id);

        assertEq(token.balanceOf(alice), aliceBefore + AMOUNT);
        assertEq(holds.heldOf(bob), 0);
        assertEq(token.getFrozenTokens(bob), 0, "the register and the token stay in step");
        assertEq(uint8(disputes.dispute(id).status), uint8(DisputeReversal.Status.Reversed));
    }

    function test_Reverse_TakesOnlyWhatIsLeft() public {
        // Bob moved all but 3,000 on before the dispute was opened.
        uint256 keep = 3_000 * HKD;
        uint256 movedOn = token.balanceOf(bob) - keep;
        vm.prank(bob);
        token.transfer(otherCustomers, movedOn);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 id = _open();
        _propose(id);
        vm.prank(compliance);
        disputes.approve(id);
        assertEq(token.balanceOf(alice), aliceBefore + keep);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Reverse_NeverCutsIntoAnotherHold() public {
        uint256 movedOn = token.balanceOf(bob) - AMOUNT;
        vm.prank(bob);
        token.transfer(otherCustomers, movedOn);
        vm.prank(compliance);
        holds.place(bob, 5_000 * HKD, Roles.COMPLIANCE, "suspicious activity");
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 id = _open();
        _propose(id);
        vm.prank(compliance);
        disputes.approve(id);
        assertEq(token.balanceOf(alice), aliceBefore + AMOUNT - 5_000 * HKD);
        assertEq(token.getFrozenTokens(bob), 5_000 * HKD);
        assertEq(holds.heldOf(bob), 5_000 * HKD);
    }

    function test_Reverse_MakerCannotApprove() public {
        _grantStaff(backOffice, Roles.COMPLIANCE);
        uint256 id = _open();
        _propose(id);
        vm.prank(backOffice);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.AlreadyActed.selector, backOffice, id));
        disputes.approve(id);
    }

    function test_Reverse_OnlyOnceProposed() public {
        uint256 id = _open();
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.NotStatus.selector, id, DisputeReversal.Status.Open));
        disputes.approve(id);
    }

    function test_Reject_LiftsTheHoldAndMovesNothing() public {
        uint256 bobBefore = token.balanceOf(bob);
        uint256 id = _open();
        vm.prank(compliance);
        disputes.reject(id);
        assertEq(holds.heldOf(bob), 0);
        assertEq(token.balanceOf(bob), bobBefore);
    }

    function test_Roles_EachStepItsOwn() public {
        vm.prank(backOffice);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.NotRole.selector, backOffice, Roles.SUPPORT));
        disputes.open(alice, bob, AMOUNT, OPERATION);
        uint256 id = _open();
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.NotRole.selector, support, Roles.BACK_OFFICE));
        disputes.propose(id);
        _propose(id);
        vm.prank(backOffice);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.NotRole.selector, backOffice, Roles.COMPLIANCE));
        disputes.approve(id);
    }

    /// @dev Not even compliance lifts a dispute's hold directly, so the dispute can always be settled.
    function test_Hold_OnlyTheModuleLiftsADisputeHold() public {
        uint256 id = _open();
        uint256 holdId = disputes.dispute(id).holdId;
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotLifter.selector, supervisor, SUPERVISOR_1, holdId));
        holds.lift(holdId, SUPERVISOR_1);
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(HoldRegister.NotLifter.selector, compliance, Roles.COMPLIANCE, holdId));
        holds.lift(holdId, Roles.COMPLIANCE);
    }

    function test_Open_OnceForAnOperation() public {
        _open();
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.AlreadyDisputed.selector, OPERATION));
        disputes.open(alice, bob, AMOUNT, OPERATION);
    }

    function test_Open_OnlyForACustomerWhoCanBeRepaid() public {
        address stranger = makeAddr("stranger");
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.CannotRepay.selector, stranger));
        disputes.open(stranger, bob, AMOUNT, OPERATION);
    }

    function test_ThreePeople_OpenerCannotPropose() public {
        _grantStaff(support, Roles.BACK_OFFICE);
        uint256 id = _open();
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.AlreadyActed.selector, support, id));
        disputes.propose(id);
    }

    function test_ThreePeople_OpenerCannotApprove() public {
        _grantStaff(support, Roles.COMPLIANCE);
        uint256 id = _open();
        _propose(id);
        vm.prank(support);
        vm.expectRevert(abi.encodeWithSelector(DisputeReversal.AlreadyActed.selector, support, id));
        disputes.approve(id);
    }

    function test_Reject_OnceProposed() public {
        uint256 id = _open();
        _propose(id);
        vm.prank(compliance);
        disputes.reject(id);
        assertEq(holds.heldOf(bob), 0);
        assertEq(uint8(disputes.dispute(id).status), uint8(DisputeReversal.Status.Rejected));
    }

    function test_Wiring_TheModuleForcesAndHolds() public view {
        assertTrue(_holds(Roles.ENFORCER, address(disputes)));
        assertTrue(_holds(Roles.DISPUTE_HOLDER, address(disputes)));
        assertFalse(_holds(Roles.DISPUTE_HOLDER, governance));
    }

    function _open() private returns (uint256) {
        vm.prank(support);
        return disputes.open(alice, bob, AMOUNT, OPERATION);
    }

    function _propose(uint256 id) private {
        vm.prank(backOffice);
        disputes.propose(id);
    }
}
