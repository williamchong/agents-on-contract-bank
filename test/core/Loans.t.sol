// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {LendingGuard} from "../../contracts/core/LendingGuard.sol";
import {Loans} from "../../contracts/core/Loans.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the loans module against open question 25 in docs/plan.md and the propose loan row of
/// the permission matrix in docs/roles.md: the credit officer proposes, a supervisor of the branch other
/// than the proposer approves within the lending caps, counting loans approved and not yet drawn, and
/// the borrower's acceptance draws the loan through the lending guard, or leaves it approved if the
/// guard refuses.
contract LoansTest is BankFixture {
    uint64 constant SUPERVISOR_1 = 102;
    uint64 constant SUPERVISOR_2 = 202;
    uint256 constant LOAN = 400_000 * HKD;

    address officer;
    address supervisor;
    address supervisor2;

    function setUp() public override {
        super.setUp();
        officer = _staff("credit officer");
        supervisor = _staff("supervisor");
        supervisor2 = _staff("supervisor 2");
        _grantStaff(officer, Roles.CREDIT_OFFICER);
        vm.startPrank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, supervisor, 0);
        manager.grantRole(SUPERVISOR_2, supervisor2, 0);
        vm.stopPrank();
        _attestFigures();
    }

    // Proposal to drawdown

    function test_Loan_ProposedApprovedAcceptedAndDrawn() public {
        bytes32 ref = _propose(alice, LOAN);
        Loans.Loan memory l = loans.loan(ref);
        assertEq(uint8(l.status), uint8(Loans.Status.Proposed));
        assertEq(l.terms.rateBps, LOAN_RATE_BPS);
        assertEq(l.terms.instalments, LOAN_INSTALMENTS);

        _approve(ref);
        assertEq(loans.exposure(alice), LOAN);
        assertEq(loans.totalExposure(), LOAN);

        uint256 balance = token.balanceOf(alice);
        vm.expectEmit(address(loans));
        emit Loans.LoanDrawn(ref, alice, LOAN);
        vm.prank(alice);
        loans.accept(ref);
        l = loans.loan(ref);
        assertEq(uint8(l.status), uint8(Loans.Status.Drawn));
        assertEq(l.approver, supervisor);
        assertEq(l.drawnAt, block.timestamp);
        assertEq(token.balanceOf(alice), balance + LOAN);
        assertEq(loans.exposure(alice), LOAN, "a loan drawn stays outstanding");
        _assertBooksBalance();
    }

    function test_Loan_TermsInForceWhenProposed() public {
        bytes32 ref = _propose(alice, LOAN);
        _govern(address(loans), abi.encodeCall(Loans.setTerms, (Loans.Terms(700, 24))));
        assertEq(loans.loan(ref).terms.rateBps, LOAN_RATE_BPS);
        assertEq(loans.loan(_propose(bob, LOAN)).terms.rateBps, 700);
    }

    // Who may act

    function test_Propose_OnlyCreditOfficer() public {
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, supervisor));
        loans.propose(alice, 1, LOAN);
    }

    function test_Propose_RefusesNoBranchAndNoAmount() public {
        vm.startPrank(officer);
        vm.expectRevert(abi.encodeWithSelector(Roles.InvalidBranchRole.selector, 0, Roles.SUPERVISOR));
        loans.propose(alice, 0, LOAN);
        vm.expectRevert(Loans.ZeroAmount.selector);
        loans.propose(alice, 1, 0);
        vm.stopPrank();
    }

    function test_Approve_OfficerCannotApproveTheirOwn() public {
        vm.prank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, officer, 0);
        bytes32 ref = _propose(alice, LOAN);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(Loans.OfficerCannotApprove.selector, officer, ref));
        loans.approve(ref);
    }

    function test_Approve_OnlyASupervisorOfTheBranch() public {
        bytes32 ref = _propose(alice, LOAN);
        vm.prank(supervisor2);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotSupervisor.selector, supervisor2, 1));
        loans.approve(ref);
    }

    function test_Accept_OnlyTheBorrower() public {
        bytes32 ref = _propose(alice, LOAN);
        _approve(ref);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotItsBorrower.selector, ref, bob));
        loans.accept(ref);
    }

    function test_Accept_NotBeforeApproval() public {
        bytes32 ref = _propose(alice, LOAN);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotApproved.selector, ref, Loans.Status.Proposed));
        loans.accept(ref);
    }

    function test_Accept_RefusedOnceItsOfficerHasLeft() public {
        bytes32 ref = _propose(alice, LOAN);
        _approve(ref);
        vm.prank(governance);
        staffRoles.revoke(officer, Roles.CREDIT_OFFICER);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotCreditOfficer.selector, officer));
        loans.accept(ref);
    }

    function test_Recovered_StaffCannotProposeOrApprove() public {
        vm.mockCall(address(recovery), abi.encodeWithSelector(recovery.involved.selector, alice, officer), abi.encode(true));
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(Loans.RecoveredTheAccount.selector, officer, alice));
        loans.propose(alice, 1, LOAN);

        vm.clearMockedCalls();
        bytes32 ref = _propose(alice, LOAN);
        vm.mockCall(address(recovery), abi.encodeWithSelector(recovery.involved.selector, alice, supervisor), abi.encode(true));
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(Loans.RecoveredTheAccount.selector, supervisor, alice));
        loans.approve(ref);
    }

    function test_OwnLoan_StaffCannotLendToThemselves() public {
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(Loans.OwnLoan.selector, officer));
        loans.propose(officer, 1, LOAN);

        bytes32 ref = _propose(supervisor, LOAN);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(Loans.OwnLoan.selector, supervisor));
        loans.approve(ref);
    }

    // The lending caps

    function test_Caps_PerCustomerCountsLoansApprovedAndNotDrawn() public {
        _approve(_propose(alice, LOAN));
        bytes32 second = _propose(alice, 300_000 * HKD);
        vm.prank(supervisor);
        vm.expectRevert(
            abi.encodeWithSelector(Loans.PerCustomerCapExceeded.selector, alice, 700_000 * HKD, PER_CUSTOMER_LENDING_CAP)
        );
        loans.approve(second);
    }

    function test_Caps_TotalCountsLoansApprovedAndNotDrawn() public {
        _govern(address(loans), abi.encodeCall(Loans.setCaps, (Loans.Caps(PER_CUSTOMER_LENDING_CAP, 700_000 * HKD))));
        _approve(_propose(alice, LOAN));
        bytes32 second = _propose(bob, LOAN);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(Loans.TotalCapExceeded.selector, 800_000 * HKD, 700_000 * HKD));
        loans.approve(second);
    }

    // Refused, cancelled, and refused by the guard

    function test_Refuse_BySupervisor() public {
        bytes32 ref = _propose(alice, LOAN);
        vm.prank(supervisor);
        loans.refuse(ref);
        assertEq(uint8(loans.loan(ref).status), uint8(Loans.Status.Refused));
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotProposed.selector, ref, Loans.Status.Refused));
        loans.approve(ref);
    }

    function test_Cancel_OnlyItsOfficerAndReleasesTheCaps() public {
        bytes32 ref = _propose(alice, LOAN);
        _approve(ref);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotItsOfficer.selector, ref, supervisor));
        loans.cancel(ref);

        vm.prank(officer);
        loans.cancel(ref);
        assertEq(loans.exposure(alice), 0);
        assertEq(loans.totalExposure(), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotApproved.selector, ref, Loans.Status.Cancelled));
        loans.accept(ref);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotOpen.selector, ref, Loans.Status.Cancelled));
        loans.cancel(ref);
    }

    function test_GuardRefuses_LoanStaysApproved() public {
        _govern(address(guard), abi.encodeCall(LendingGuard.setMinimums, (990, LIQUIDITY_MINIMUM_BPS)));
        _attestFigures();
        bytes32 ref = _propose(alice, LOAN);
        _approve(ref);
        uint256 supply = token.totalSupply();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.CapitalRatioBelowMinimum.selector, 940, 990));
        loans.accept(ref);
        assertEq(uint8(loans.loan(ref).status), uint8(Loans.Status.Approved));
        assertEq(token.totalSupply(), supply);
    }

    function test_Governance_OnlyGovernanceSetsTermsAndCaps() public {
        vm.startPrank(officer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, officer));
        loans.setTerms(Loans.Terms(0, 1));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, officer));
        loans.setCaps(Loans.Caps(type(uint256).max, type(uint256).max));
        vm.stopPrank();
    }

    function _propose(address borrower, uint256 amount) private returns (bytes32) {
        vm.prank(officer);
        return loans.propose(borrower, 1, amount);
    }

    function _approve(bytes32 ref) private {
        vm.prank(supervisor);
        loans.approve(ref);
    }
}
