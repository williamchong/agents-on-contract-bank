// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {LendingGuard} from "../../contracts/core/LendingGuard.sol";
import {Loans} from "../../contracts/core/Loans.sol";
import {Rates} from "../../contracts/core/Rates.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the loans module against open question 25 in docs/plan.md and the propose loan row of
/// the permission matrix in docs/roles.md: the credit officer proposes, a supervisor of the branch other
/// than the proposer approves within the lending caps, counting loans approved and not yet drawn, and
/// the borrower's acceptance draws the loan through the lending guard, or leaves it approved if the
/// guard refuses. Against open question 28 and the loan in arrears scenario in docs/scenarios.md too: the
/// scheduler collects each instalment due under the borrower's mandate, a loan whose collection fails is
/// in arrears and at the third in default, its allowance moving at the set rates, and governance writes a
/// defaulted loan off.
contract LoansTest is BankFixture {
    uint64 constant SUPERVISOR_1 = 102;
    uint64 constant SUPERVISOR_2 = 202;
    uint256 constant LOAN = 400_000 * HKD;
    /// @dev The loan in arrears in docs/scenarios.md, and its instalment.
    uint256 constant SMALL_LOAN = 20_000 * HKD;
    uint256 constant INSTALMENT = 172_133;

    address officer;
    address supervisor;
    address supervisor2;
    address scheduler;

    function setUp() public override {
        super.setUp();
        officer = _staff("credit officer");
        supervisor = _staff("supervisor");
        supervisor2 = _staff("supervisor 2");
        scheduler = _staff("scheduler");
        _grantStaff(officer, Roles.CREDIT_OFFICER);
        _grantStaff(scheduler, Roles.SCHEDULER);
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
        _mandate(alice, type(uint256).max);
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

    function test_Loan_RateInForceWhenProposed() public {
        bytes32 ref = _propose(alice, LOAN);
        address treasurer = makeAddr("treasurer");
        vm.prank(address(staffRoles));
        manager.grantRole(Roles.TREASURY, treasurer, 0);
        vm.prank(treasurer);
        rates.proposeProductRates(Rates.ProductRates(SAVINGS_RATE_BPS, 700), "pricing paper");
        _govern(address(rates), abi.encodeCall(Rates.applyProductRates, ("pricing paper")));
        assertEq(loans.loan(ref).terms.rateBps, LOAN_RATE_BPS);
        Loans.Terms memory terms = loans.loan(_propose(bob, LOAN)).terms;
        assertEq(terms.rateBps, 700);
        assertEq(terms.instalments, LOAN_INSTALMENTS);
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
        _mandate(alice, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingGuard.CapitalRatioBelowMinimum.selector, 940, 990));
        loans.accept(ref);
        assertEq(uint8(loans.loan(ref).status), uint8(Loans.Status.Approved));
        assertEq(token.totalSupply(), supply);
    }

    function test_Governance_OnlyGovernanceSetsCaps() public {
        vm.startPrank(officer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, officer));
        loans.setCaps(Loans.Caps(type(uint256).max, type(uint256).max));
        vm.stopPrank();
    }

    // The mandate

    function test_Accept_RefusedWithoutAMandateForEveryInstalment() public {
        bytes32 ref = _propose(alice, SMALL_LOAN);
        _approve(ref);
        _mandate(alice, INSTALMENT * 12 - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Loans.MandateTooSmall.selector, INSTALMENT * 12 - 1, INSTALMENT * 12));
        loans.accept(ref);
    }

    // Instalments

    function test_Annuity_AtTheLoanRate() public view {
        assertEq(loans.annuity(SMALL_LOAN, Loans.Terms(LOAN_RATE_BPS, LOAN_INSTALMENTS)), INSTALMENT);
        assertEq(loans.annuity(1_200, Loans.Terms(0, 12)), 100, "with no interest, the principal in equal parts");
    }

    /// @dev Twelve instalments of 1,721.33 and a last of 1,721.25 repay 20,000 with 655.88 of interest.
    function test_Collect_TwelveInstalmentsRepayTheLoanExactly() public {
        int256 loansBefore = ledger.balanceOf(GeneralLedger.Account.Loans);
        int256 equityBefore = ledger.balanceOf(GeneralLedger.Account.Equity);
        int256 allowanceBefore = ledger.balanceOf(GeneralLedger.Account.Allowance);
        bytes32 ref = _draw(alice, SMALL_LOAN);
        uint256 balance = token.balanceOf(alice);
        for (uint256 i = 1; i <= LOAN_INSTALMENTS; ++i) {
            skip(INSTALMENT_PERIOD);
            _collect(ref);
            assertEq(loans.loan(ref).paid, i);
        }
        Loans.Loan memory l = loans.loan(ref);
        assertEq(uint8(l.status), uint8(Loans.Status.Repaid));
        assertEq(l.outstanding, 0);
        assertEq(l.allowance, 0);
        assertEq(balance - token.balanceOf(alice), 2_065_588, "the instalments add up to the loan and its interest");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Loans), loansBefore);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Allowance), allowanceBefore);
        assertEq(equityBefore - ledger.balanceOf(GeneralLedger.Account.Equity), 65_588, "the interest is income");
        assertEq(loans.exposure(alice), 0);
        assertEq(token.balanceOf(address(loans)), 0, "the module keeps nothing it collects");
        _assertBooksBalance();
    }

    /// @dev Whatever the amount, the term repays it exactly, the last instalment no larger than the rest.
    function testFuzz_Collect_TermRepaysAnyLoanExactly(uint32 cents) public {
        uint256 amount = bound(cents, 1, PER_CUSTOMER_LENDING_CAP);
        bytes32 ref = _draw(alice, amount);
        uint256 instalment = loans.loan(ref).instalment;
        uint256 balance = token.balanceOf(alice);
        skip(LOAN_INSTALMENTS * INSTALMENT_PERIOD);
        _collect(ref);
        Loans.Loan memory l = loans.loan(ref);
        assertEq(uint8(l.status), uint8(Loans.Status.Repaid));
        assertEq(l.outstanding, 0);
        assertLe(balance - token.balanceOf(alice), instalment * LOAN_INSTALMENTS);
        assertGe(balance - token.balanceOf(alice), amount);
        assertEq(loans.exposure(alice), 0);
        _assertBooksBalance();
    }

    function test_Collect_OnlyWhatIsDueAndOnce() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        _collect(ref);
        assertEq(loans.loan(ref).paid, 0, "nothing is due before the first period");
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        uint256 entries = ledger.entryCount();
        _collect(ref);
        assertEq(loans.loan(ref).paid, 1);
        assertEq(ledger.entryCount(), entries, "a second trigger posts nothing");
    }

    function test_Collect_CatchesUpEveryInstalmentAfterAJump() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        skip(3 * INSTALMENT_PERIOD);
        for (uint256 i = 1; i <= 3; ++i) {
            vm.expectEmit(true, false, false, false, address(loans));
            emit Loans.InstalmentCollected(ref, i, 0, 0);
        }
        _collect(ref);
        assertEq(loans.loan(ref).paid, 3);
        assertEq(uint8(loans.loan(ref).stage), uint8(Loans.Stage.Performing));
    }

    function test_Collect_ExposureFallsWithThePrincipal() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        assertEq(loans.exposure(alice), loans.loan(ref).outstanding);
        assertEq(loans.exposure(alice), SMALL_LOAN - (INSTALMENT - 10_000));
    }

    function test_Collect_OnlyScheduler() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, officer));
        loans.collectDue(ref);
    }

    function test_Collect_NotBeforeTheLoanIsDrawn() public {
        bytes32 ref = _propose(alice, SMALL_LOAN);
        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotDrawn.selector, ref, Loans.Status.Proposed));
        loans.collectDue(ref);
    }

    // Arrears, default and write-off

    /// @dev The table in docs/scenarios.md: the mandate cancelled, three instalments missed.
    function test_MandateCancelled_ArrearsThenDefault() public {
        int256 equityBefore = ledger.balanceOf(GeneralLedger.Account.Equity);
        bytes32 ref = _draw(alice, SMALL_LOAN);
        assertEq(loans.loan(ref).allowance, 200 * HKD);
        _mandate(alice, 0);

        uint256[3] memory allowance = [uint256(2_000 * HKD), 2_000 * HKD, 12_000 * HKD];
        Loans.Stage[3] memory stage = [Loans.Stage.Arrears, Loans.Stage.Arrears, Loans.Stage.Default];
        for (uint256 i = 0; i < 3; ++i) {
            skip(INSTALMENT_PERIOD);
            vm.expectEmit(address(loans));
            emit Loans.CollectionMissed(ref, i + 1, stage[i]);
            _collect(ref);
            Loans.Loan memory l = loans.loan(ref);
            assertEq(uint8(l.stage), uint8(stage[i]));
            assertEq(l.allowance, allowance[i]);
            assertEq(ledger.balanceOf(GeneralLedger.Account.Equity) - equityBefore, int256(allowance[i]), "the allowance is charged to equity");
        }
        assertEq(loans.loan(ref).outstanding, SMALL_LOAN);
        _assertBooksBalance();
    }

    /// @dev Cancelling one loan's mandate leaves the borrower's other loans collected.
    function test_MandateCancelled_OneLoanOnly() public {
        bytes32 first = _draw(alice, SMALL_LOAN);
        bytes32 second = _draw(alice, SMALL_LOAN);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotItsBorrower.selector, second, bob));
        loans.cancelMandate(second);
        vm.prank(alice);
        loans.cancelMandate(second);

        skip(INSTALMENT_PERIOD);
        _collect(first);
        _collect(second);
        assertEq(loans.loan(first).paid, 1);
        assertEq(uint8(loans.loan(second).stage), uint8(Loans.Stage.Arrears));

        vm.prank(alice);
        loans.renewMandate(second);
        skip(INSTALMENT_PERIOD);
        _collect(second);
        assertEq(loans.loan(second).paid, 2);
        assertEq(uint8(loans.loan(second).stage), uint8(Loans.Stage.Performing));
    }

    function test_EmptyAccount_MissesTheInstalment() public {
        bytes32 ref = _draw(bob, SMALL_LOAN);
        // Bob's money leaves his account, as the cash module would take it at the counter.
        uint256 all = token.balanceOf(bob);
        vm.prank(address(cash));
        token.forcedTransfer(bob, otherCustomers, all);
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        assertEq(uint8(loans.loan(ref).stage), uint8(Loans.Stage.Arrears));
    }

    function test_Arrears_PerformingAgainOnceCaughtUp() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        _mandate(alice, 0);
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        assertEq(uint8(loans.loan(ref).stage), uint8(Loans.Stage.Arrears));

        _mandate(alice, type(uint256).max);
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        Loans.Loan memory l = loans.loan(ref);
        assertEq(l.paid, 2);
        assertEq(uint8(l.stage), uint8(Loans.Stage.Performing));
        assertEq(l.allowance, (l.outstanding + 99) / 100, "back to the performing rate on what is outstanding");
    }

    function test_Default_StaysOnceAPaymentIsTaken() public {
        bytes32 ref = _defaulted(alice);
        _mandate(alice, type(uint256).max);
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        Loans.Loan memory l = loans.loan(ref);
        assertEq(l.paid, 4);
        assertEq(uint8(l.stage), uint8(Loans.Stage.Default));
        assertEq(l.allowance, (l.outstanding * 60 + 99) / 100);
    }

    function test_AllowanceRates_ReachALoanAtItsNextMeasure() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        _mandate(alice, 0);
        _setAllowanceRates(PERFORMING_ALLOWANCE_BPS, 2_000, DEFAULT_ALLOWANCE_BPS);
        assertEq(loans.loan(ref).allowance, 200 * HKD);
        skip(INSTALMENT_PERIOD);
        _collect(ref);
        assertEq(loans.loan(ref).allowance, 4_000 * HKD);
    }

    /// @dev Equity falls by the whole loan: 12,000 through the allowance and the 8,000 shortfall.
    function test_WriteOff_AgainstTheAllowanceWithTheShortfallOnEquity() public {
        int256 loansBefore = ledger.balanceOf(GeneralLedger.Account.Loans);
        int256 allowanceBefore = ledger.balanceOf(GeneralLedger.Account.Allowance);
        int256 equityBefore = ledger.balanceOf(GeneralLedger.Account.Equity);
        bytes32 ref = _defaulted(alice);

        bytes memory data = abi.encodeCall(Loans.writeOff, (ref));
        bytes32 salt = _schedule(address(loans), data, _quorum());
        vm.expectEmit(address(guard));
        emit LendingGuard.WriteOffPosted(ref, SMALL_LOAN, 12_000 * HKD, 8_000 * HKD);
        _execute(address(loans), data, salt);
        Loans.Loan memory l = loans.loan(ref);
        assertEq(uint8(l.status), uint8(Loans.Status.WrittenOff));
        assertEq(l.outstanding, 0);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Loans), loansBefore);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Allowance), allowanceBefore);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Equity) - equityBefore, int256(SMALL_LOAN));
        assertEq(loans.exposure(alice), 0);
        _assertBooksBalance();

        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotDrawn.selector, ref, Loans.Status.WrittenOff));
        loans.collectDue(ref);
    }

    function test_WriteOff_OnlyADefaultedLoanAndOnlyGovernance() public {
        bytes32 ref = _draw(alice, SMALL_LOAN);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Loans.NotInDefault.selector, ref, Loans.Stage.Performing));
        loans.writeOff(ref);
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, officer));
        loans.writeOff(ref);
    }

    function _propose(address borrower, uint256 amount) private returns (bytes32) {
        vm.prank(officer);
        return loans.propose(borrower, 1, amount);
    }

    function _approve(bytes32 ref) private {
        vm.prank(supervisor);
        loans.approve(ref);
    }

    /// @dev The borrower's mandate to the loans module, as their acceptance gives it.
    function _mandate(address borrower, uint256 amount) private {
        vm.prank(borrower);
        token.approve(address(loans), amount);
    }

    /// @dev A loan proposed, approved and accepted with a mandate for every instalment.
    function _draw(address borrower, uint256 amount) private returns (bytes32 ref) {
        ref = _propose(borrower, amount);
        _approve(ref);
        _mandate(borrower, type(uint256).max);
        vm.prank(borrower);
        loans.accept(ref);
    }

    /// @dev The loan in arrears in docs/scenarios.md, its mandate cancelled until three instalments are missed.
    function _defaulted(address borrower) private returns (bytes32 ref) {
        ref = _draw(borrower, SMALL_LOAN);
        _mandate(borrower, 0);
        skip(3 * INSTALMENT_PERIOD);
        _collect(ref);
    }

    function _collect(bytes32 ref) private {
        vm.prank(scheduler);
        loans.collectDue(ref);
    }
}
