// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Roles} from "../../contracts/core/Roles.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {BranchApprovals} from "../../contracts/core/BranchApprovals.sol";
import {AssistedOperations} from "../../contracts/core/AssistedOperations.sol";
import {CashOperations} from "../../contracts/core/CashOperations.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks operations through a teller against the branch approval ladder in docs/roles.md and the
/// paper instruction flow in docs/architecture.md: the money is held while approvers are due, they
/// approve in order and each differs from the teller and every earlier one, a paper instruction never
/// takes more than the unfrozen balance, and refusal or cancellation gives the money back. Transfers and
/// payments out go through the assisted operations module and withdrawals at the counter through the
/// cash module.
contract AssistedOperationsTest is BankFixture {
    uint64 constant TELLER_1 = 101;
    uint64 constant SUPERVISOR_1 = 102;
    uint64 constant MANAGER_1 = 103;
    uint64 constant TELLER_2 = 201;
    bytes32 constant SLIP = keccak256("scan of a signed paper slip");
    bytes32 constant PAYEE = keccak256("a payee at another bank");

    address supervisor;
    address branchManager;
    address compliance;
    address redTeam;
    MultiSignerAccount carol;
    uint256 cardKey = _key("carol's card");

    function setUp() public override {
        super.setUp();
        supervisor = _staff("supervisor");
        branchManager = _staff("branch manager");
        compliance = _staff("compliance");
        redTeam = _staff("red team");
        _grantStaff(compliance, Roles.COMPLIANCE);
        // Branch roles are granted directly; the branch manager's path is checked in StaffRolesTest.
        vm.startPrank(address(staffRoles));
        manager.grantRole(TELLER_1, teller1, 0);
        manager.grantRole(SUPERVISOR_1, supervisor, 0);
        manager.grantRole(MANAGER_1, branchManager, 0);
        manager.grantRole(TELLER_2, redTeam, 0);
        vm.stopPrank();

        uint256[] memory keys = new uint256[](1);
        keys[0] = cardKey;
        carol = new MultiSignerAccount(_verifiers(), _signers(keys), 1, address(recovery));
        vm.prank(governance);
        token.allowUser(address(carol));
        vm.prank(otherCustomers);
        token.transfer(address(carol), 1_000_000 * HKD);
    }

    // The ladder

    function test_Ladder_AsRolesSays() public view {
        BranchApprovals.Authorisation signed = BranchApprovals.Authorisation.Signed;
        BranchApprovals.Authorisation paper = BranchApprovals.Authorisation.Paper;
        assertEq(assisted.approversRequired(50_000 * HKD, signed), 0, "teller alone");
        assertEq(assisted.approversRequired(50_000 * HKD + 1, signed), 1, "and supervisor");
        assertEq(assisted.approversRequired(500_000 * HKD, signed), 1);
        assertEq(assisted.approversRequired(500_000 * HKD + 1, signed), 2, "and branch manager");
        assertEq(assisted.approversRequired(1, paper), 1, "every debit on paper needs an approver");
        assertEq(assisted.approversRequired(500_000 * HKD, paper), 2);
        assertEq(assisted.approversRequired(500_000 * HKD + 1, paper), 3, "and compliance");
    }

    function test_Ladder_StepsInOrder() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.InvalidLadder.selector, BranchApprovals.Ladder(20, 10)));
        assisted.setLadder(BranchApprovals.Ladder(20, 10));
    }

    function test_Ladder_SetByGovernance() public {
        vm.prank(governance);
        assisted.setLadder(BranchApprovals.Ladder(10 * HKD, 20 * HKD));
        assertEq(assisted.approversRequired(11 * HKD, BranchApprovals.Authorisation.Signed), 1);
    }

    // Signed by the customer

    function test_Signed_SmallTransferNeedsNoApprover() public {
        uint256 before = token.balanceOf(bob);
        bytes32 ref = _transferSigned(1_000 * HKD);
        assertEq(token.balanceOf(bob), before + 1_000 * HKD);
        assertEq(uint8(assisted.operation(ref).status), uint8(BranchApprovals.Status.CarriedOut));
        assertEq(token.balanceOf(address(assisted)), 0);
    }

    function test_Signed_LargerTransferWaitsForTheSupervisor() public {
        uint256 before = token.balanceOf(bob);
        uint256 carolBefore = token.balanceOf(address(carol));
        bytes32 ref = _transferSigned(60_000 * HKD);

        assertEq(token.balanceOf(bob), before, "nothing reaches the recipient yet");
        assertEq(token.balanceOf(address(carol)), carolBefore - 60_000 * HKD, "the money is held");
        assertEq(assisted.waitingTotal(), 60_000 * HKD);
        assertEq(assisted.nextApproverRole(ref), SUPERVISOR_1);

        _approve(supervisor, ref);
        assertEq(token.balanceOf(bob), before + 60_000 * HKD);
        assertEq(assisted.waitingTotal(), 0);
        assertEq(assisted.nextApproverRole(ref), 0);
    }

    function test_Signed_AnotherCardRefused() public {
        BranchApprovals.CardAuthorisation memory a = _authorisation(1_000 * HKD);
        a.signature = _cardSignature(_key("stolen card"), address(carol), address(assisted), 1_000 * HKD, a.nonce);
        vm.prank(teller1);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        assisted.transfer(1, bob, a);
    }

    /// @dev The customer authorised a transfer to Bob; the teller cannot send it to anyone else.
    function test_Signed_CannotBeRedirected() public {
        BranchApprovals.CardAuthorisation memory a = _authorisation(1_000 * HKD);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AuthorisedForAnotherIntent.selector, a.nonce));
        assisted.transfer(1, alice, a);
    }

    /// @dev Nor can a teller of another branch use it there.
    function test_Signed_CannotBeUsedAtAnotherBranch() public {
        BranchApprovals.CardAuthorisation memory a = _authorisation(1_000 * HKD);
        vm.prank(redTeam);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AuthorisedForAnotherIntent.selector, a.nonce));
        assisted.transfer(2, bob, a);
    }

    /// @dev Nor can an authorisation for a cash withdrawal at the counter move money to anyone.
    function test_Signed_WithdrawalAuthorisationIsNotATransfer() public {
        BranchApprovals.CardAuthorisation memory a = _cardAuthorisation(
            cardKey,
            address(carol),
            address(assisted),
            cash.intentKey(cash.COUNTER_WITHDRAWAL(), 1, address(0)),
            1_000 * HKD
        );
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AuthorisedForAnotherIntent.selector, a.nonce));
        assisted.transfer(1, bob, a);
    }

    // On paper

    function test_Paper_TellerAloneCannotComplete() public {
        bytes32 ref = _transferOnPaper(alice, 1_000 * HKD);
        assertEq(uint8(assisted.operation(ref).status), uint8(BranchApprovals.Status.Waiting));
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotApprover.selector, teller1, SUPERVISOR_1));
        assisted.approve(ref);
    }

    function test_Paper_TellerWhoIsAlsoSupervisorCannotApproveTheirOwn() public {
        vm.prank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, teller1, 0);
        bytes32 ref = _transferOnPaper(alice, 1_000 * HKD);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.TellerCannotApprove.selector, teller1, ref));
        assisted.approve(ref);
    }

    function test_Paper_RecordsTellerApproversAndSlip() public {
        uint256 before = token.balanceOf(bob);
        bytes32 ref = _transferOnPaper(alice, 20_000 * HKD);
        _approve(supervisor, ref);

        BranchApprovals.Operation memory op = assisted.operation(ref);
        assertEq(op.teller, teller1);
        assertEq(op.approvers[0], supervisor);
        assertEq(op.slipHash, SLIP);
        assertEq(uint8(op.authorisation), uint8(BranchApprovals.Authorisation.Paper));
        assertEq(token.balanceOf(bob), before + 20_000 * HKD);
    }

    function test_Paper_LargestClimbsTheWholeLadderInOrder() public {
        bytes32 ref = _transferOnPaper(address(carol), 600_000 * HKD);
        // Compliance cannot act before the supervisor and branch manager.
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotApprover.selector, compliance, SUPERVISOR_1));
        assisted.approve(ref);

        _approve(supervisor, ref);
        assertEq(assisted.nextApproverRole(ref), MANAGER_1);
        _approve(branchManager, ref);
        assertEq(assisted.nextApproverRole(ref), Roles.COMPLIANCE);
        uint256 before = token.balanceOf(bob);
        _approve(compliance, ref);
        assertEq(token.balanceOf(bob), before + 600_000 * HKD);
    }

    function test_Paper_SamePersonCannotApproveTwice() public {
        vm.prank(address(staffRoles));
        manager.grantRole(MANAGER_1, supervisor, 0);
        bytes32 ref = _transferOnPaper(address(carol), 100_000 * HKD);
        _approve(supervisor, ref);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AlreadyApproved.selector, supervisor, ref));
        assisted.approve(ref);
    }

    function test_Paper_NeverBeyondTheUnfrozenBalance() public {
        address support = _staff("support");
        _grantStaff(support, Roles.SUPPORT);
        vm.prank(support);
        holds.place(alice, 90_000 * HKD, Roles.SUPPORT, "dispute opened");

        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.InsufficientUnfrozen.selector, alice, 10_000 * HKD, 20_000 * HKD));
        assisted.transferOnPaper(1, alice, bob, 20_000 * HKD, SLIP);
    }

    function test_Paper_NotForABlockedCustomer() public {
        vm.prank(compliance);
        token.blockUser(alice);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.BlockedCustomer.selector, alice));
        assisted.transferOnPaper(1, alice, bob, HKD, SLIP);
    }

    function test_Paper_NeedsTheSlip() public {
        vm.prank(teller1);
        vm.expectRevert(BranchApprovals.NoSlip.selector);
        assisted.transferOnPaper(1, alice, bob, HKD, 0);
    }

    // Refusal, cancellation and scope

    function test_Refuse_GivesTheMoneyBack() public {
        uint256 before = token.balanceOf(alice);
        bytes32 ref = _transferOnPaper(alice, 5_000 * HKD);
        vm.prank(supervisor);
        assisted.refuse(ref);
        assertEq(token.balanceOf(alice), before);
        assertEq(uint8(assisted.operation(ref).status), uint8(BranchApprovals.Status.Refused));
        assertEq(assisted.waitingTotal(), 0);
    }

    function test_Cancel_OnlyByItsTeller() public {
        uint256 before = token.balanceOf(alice);
        bytes32 ref = _transferOnPaper(alice, 5_000 * HKD);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotItsTeller.selector, ref, supervisor));
        assisted.cancel(ref);
        vm.prank(teller1);
        assisted.cancel(ref);
        assertEq(token.balanceOf(alice), before);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotWaiting.selector, ref, BranchApprovals.Status.Cancelled));
        assisted.approve(ref);
    }

    function test_Scope_TellerOfAnotherBranchRefused() public {
        vm.prank(redTeam);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotTeller.selector, redTeam, 1));
        assisted.transferOnPaper(1, alice, bob, HKD, SLIP);
    }

    function test_Scope_RecipientMustBeOnboarded() public {
        address stranger = makeAddr("stranger");
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(AssistedOperations.NotAdmitted.selector, stranger));
        assisted.transferOnPaper(1, alice, stranger, HKD, SLIP);
    }

    /// @dev A payment out goes through pay, which records it; a transfer to the payments module would not.
    function test_Scope_RecipientIsNoBankModule() public {
        vm.startPrank(teller1);
        vm.expectRevert(abi.encodeWithSelector(AssistedOperations.NotAdmitted.selector, address(payments)));
        assisted.transferOnPaper(1, alice, address(payments), HKD, SLIP);
        vm.expectRevert(abi.encodeWithSelector(AssistedOperations.NotAdmitted.selector, address(assisted)));
        assisted.transferOnPaper(1, alice, address(assisted), HKD, SLIP);
        vm.stopPrank();
    }

    function test_Scope_CustomerBlockedBeforeTheLastApproval() public {
        bytes32 ref = _transferOnPaper(alice, 5_000 * HKD);
        vm.prank(compliance);
        token.blockUser(alice);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.BlockedCustomer.selector, alice));
        assisted.approve(ref);
    }

    function test_Scope_TellerRevokedBeforeTheLastApproval() public {
        bytes32 ref = _transferOnPaper(alice, 5_000 * HKD);
        vm.prank(address(staffRoles));
        manager.revokeRole(TELLER_1, teller1);
        vm.prank(supervisor);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotTeller.selector, teller1, 1));
        assisted.approve(ref);
    }

    // Payments out through a teller

    function test_Payment_SmallSignedQueuedInTheCustomersName() public {
        bytes32 ref = _paySigned(PAYEE, 1_000 * HKD);
        assertEq(uint8(assisted.operation(ref).status), uint8(BranchApprovals.Status.CarriedOut));
        Payments.Payment memory p = payments.outgoing(_lastPayment());
        assertEq(p.party, address(carol), "the customer is the payer, not the module");
        assertEq(p.amount, 1_000 * HKD);
        assertEq(uint8(p.status), uint8(Payments.Status.Queued));
        assertEq(token.balanceOf(address(assisted)), 0);
        assertEq(token.allowance(address(assisted), address(payments)), 0);
    }

    function test_Payment_HandedOverUnderItsReference() public {
        BranchApprovals.CardAuthorisation memory a = _paymentAuthorisation(PAYEE, 1_000 * HKD);
        vm.expectEmit(false, false, false, false, address(assisted));
        emit AssistedOperations.PaymentHandedOver(bytes32(0), bytes32(0));
        vm.prank(teller1);
        assisted.pay(1, PAYEE, a);
    }

    /// @dev The ladder first, then screening: the supervisor approves, and compliance still clears or
    /// stops a payment at or above the screening threshold. One stopped goes back to the customer.
    function test_Payment_LargerClimbsTheLadderThenWaitsForCompliance() public {
        uint256 before = token.balanceOf(address(carol));
        bytes32 ref = _paySigned(PAYEE, 60_000 * HKD);
        assertEq(payments.orderCount(), 0, "nothing reaches the payments module before the supervisor");

        _approve(supervisor, ref);
        bytes32 paymentRef = _lastPayment();
        assertEq(uint8(payments.outgoing(paymentRef).status), uint8(Payments.Status.Screening));

        vm.prank(compliance);
        payments.returnOutgoing(paymentRef);
        assertEq(token.balanceOf(address(carol)), before);
        assertEq(token.balanceOf(address(payments)), 0);
    }

    function test_Payment_RejectedComesBackToTheCustomer() public {
        uint256 before = token.balanceOf(alice);
        bytes32 ref = _payOnPaper(alice, 5_000 * HKD);
        _approve(supervisor, ref);
        bytes32 paymentRef = _lastPayment();
        payments.release(1);
        assertEq(token.balanceOf(alice), before - 5_000 * HKD);

        _rejectPayment(paymentRef, 5_000 * HKD);
        assertEq(token.balanceOf(alice), before);
        assertEq(token.balanceOf(address(assisted)), 0);
        _assertBooksBalance();
    }

    /// @dev The customer authorised a payment to one payee; the teller cannot send it to another.
    function test_Payment_CannotBeRedirected() public {
        BranchApprovals.CardAuthorisation memory a = _paymentAuthorisation(PAYEE, 1_000 * HKD);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AuthorisedForAnotherIntent.selector, a.nonce));
        assisted.pay(1, keccak256("someone else at another bank"), a);
    }

    /// @dev Nor can an authorisation of a transfer to Bob be paid out to another bank.
    function test_Payment_TransferAuthorisationIsNotAPayment() public {
        BranchApprovals.CardAuthorisation memory a = _authorisation(1_000 * HKD);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AuthorisedForAnotherIntent.selector, a.nonce));
        assisted.pay(1, PAYEE, a);
    }

    function test_Payment_NeedsAPayee() public {
        vm.prank(teller1);
        vm.expectRevert(AssistedOperations.NoPayee.selector);
        assisted.payOnPaper(1, alice, 0, HKD, SLIP);
    }

    /// @dev The branch's channel is its ladder: a payment through a teller counts against neither the
    /// app limit nor the unregistered payee limit, so it can go beyond both.
    function test_Payment_NotCountedAgainstTheCustomersLimits() public {
        vm.prank(governance);
        limits.enrol(alice);
        bytes32 ref = _payOnPaper(alice, APP_LIMIT * 2);
        _approve(supervisor, ref);
        assertEq(payments.outgoing(_lastPayment()).amount, APP_LIMIT * 2);

        vm.startPrank(alice);
        token.approve(address(payments), UNREGISTERED_PAYEE_LIMIT);
        payments.pay(UNREGISTERED_PAYEE_LIMIT, PAYEE);
        vm.stopPrank();
    }

    // Withdrawals at the counter

    function test_Counter_SmallSignedWithdrawalPaidFromTheDrawer() public {
        bytes32 drawer = cash.locationId(_drawer(1, teller1));
        uint256 inDrawer = cash.cashAt(drawer);
        int256 ledgerCash = ledger.balanceOf(GeneralLedger.Account.Cash);
        uint256 supply = token.totalSupply();
        BranchApprovals.CardAuthorisation memory a = _cardAuthorisation(
            cardKey,
            address(carol),
            address(cash),
            cash.intentKey(cash.COUNTER_WITHDRAWAL(), 1, address(0)),
            3_000 * HKD
        );
        vm.prank(teller1);
        cash.withdrawAtCounter(1, a);
        assertEq(cash.cashAt(drawer), inDrawer - 3_000 * HKD);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Cash), ledgerCash - int256(3_000 * HKD));
        assertEq(token.totalSupply(), supply - 3_000 * HKD);
        _assertBooksBalance();
    }

    function test_Counter_PaperWithdrawalWaitsThenPaysOut() public {
        bytes32 drawer = cash.locationId(_drawer(1, teller1));
        uint256 inDrawer = cash.cashAt(drawer);
        uint256 before = token.balanceOf(alice);
        vm.prank(teller1);
        bytes32 ref = cash.withdrawAtCounterOnPaper(1, alice, 2_000 * HKD, SLIP);
        assertEq(cash.cashAt(drawer), inDrawer, "no cash leaves before the supervisor approves");
        assertEq(token.balanceOf(alice), before - 2_000 * HKD);

        vm.prank(supervisor);
        cash.approve(ref);
        assertEq(cash.cashAt(drawer), inDrawer - 2_000 * HKD);
        _assertBooksBalance();
    }

    function test_Counter_DrawerMustHoldTheCashWhenOpened() public {
        bytes32 drawer = cash.locationId(_drawer(1, teller1));
        uint256 inDrawer = cash.cashAt(drawer);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.InsufficientCash.selector, drawer, inDrawer, inDrawer + HKD));
        cash.withdrawAtCounterOnPaper(1, address(carol), inDrawer + HKD, SLIP);
    }

    function test_Counter_RefusedWithdrawalGivesTheMoneyBack() public {
        uint256 before = token.balanceOf(alice);
        vm.prank(teller1);
        bytes32 ref = cash.withdrawAtCounterOnPaper(1, alice, 2_000 * HKD, SLIP);
        assertEq(cash.waitingTotal(), 2_000 * HKD);
        vm.prank(supervisor);
        cash.refuse(ref);
        assertEq(token.balanceOf(alice), before);
        assertEq(cash.waitingTotal(), 0);
        assertEq(token.balanceOf(address(cash)), 0);
    }

    function test_Counter_LargeWithdrawalTellsCompliance() public {
        _openDrawerWith(CASH_REPORT_THRESHOLD);
        vm.expectEmit(false, true, false, true, address(cash));
        emit CashOperations.CashReported(bytes32(0), address(carol), CASH_REPORT_THRESHOLD);
        vm.prank(teller1);
        cash.withdrawAtCounterOnPaper(1, address(carol), CASH_REPORT_THRESHOLD, SLIP);
    }

    // Helpers

    function _transferSigned(uint256 amount) private returns (bytes32) {
        BranchApprovals.CardAuthorisation memory a = _authorisation(amount);
        vm.prank(teller1);
        return assisted.transfer(1, bob, a);
    }

    function _transferOnPaper(address customer, uint256 amount) private returns (bytes32) {
        vm.prank(teller1);
        return assisted.transferOnPaper(1, customer, bob, amount, SLIP);
    }

    function _paySigned(bytes32 payee, uint256 amount) private returns (bytes32) {
        BranchApprovals.CardAuthorisation memory a = _paymentAuthorisation(payee, amount);
        vm.prank(teller1);
        return assisted.pay(1, payee, a);
    }

    function _payOnPaper(address customer, uint256 amount) private returns (bytes32) {
        vm.prank(teller1);
        return assisted.payOnPaper(1, customer, PAYEE, amount, SLIP);
    }

    /// @dev The payments module's reference for the payment out it took last.
    function _lastPayment() private view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(payments), payments.orderCount()));
    }

    /// @dev Carol's card authorises a payment of `amount` to `payee` through a teller at branch 1.
    function _paymentAuthorisation(bytes32 payee, uint256 amount) private view returns (BranchApprovals.CardAuthorisation memory) {
        return
            _cardAuthorisation(
                cardKey,
                address(carol),
                address(assisted),
                assisted.intentKey(assisted.paymentPurpose(payee), 1, address(payments)),
                amount
            );
    }

    function _approve(address by, bytes32 ref) private {
        _approve(by, ref, address(assisted));
    }

    function _approve(address by, bytes32 ref, address module) private {
        vm.prank(by);
        BranchApprovals(module).approve(ref);
    }

    /// @dev Carol's card authorises a transfer of `amount` to Bob through a teller at branch 1.
    function _authorisation(uint256 amount) private view returns (BranchApprovals.CardAuthorisation memory) {
        return _cardAuthorisation(cardKey, address(carol), address(assisted), assisted.intentKey(assisted.TRANSFER(), 1, bob), amount);
    }

    /// @dev Moves cash from the vault into teller 1's drawer until it holds `amount`.
    function _openDrawerWith(uint256 amount) private {
        address custodian = _staff("custodian");
        vm.prank(address(staffRoles));
        manager.grantRole(104, custodian, 0);
        uint256 inDrawer = cash.cashAt(cash.locationId(_drawer(1, teller1)));
        vm.prank(custodian);
        uint256 id = cash.proposeMove(_vault(1), _drawer(1, teller1), amount - inDrawer);
        vm.prank(supervisor);
        cash.confirmOrder(id);
    }
}
