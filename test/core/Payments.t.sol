// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {Payments} from "../../contracts/core/Payments.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the payments module against the payment rows of the permission matrix in
/// docs/roles.md and the payment scenarios in docs/scenarios.md: payments in by signed credit advice,
/// screening and suspense, payments out queued until the settlement account covers them, and signed
/// rejections. The books balance after every step, and the module only ever holds the amounts still
/// waiting against their references.
contract PaymentsTest is BankFixture {
    uint256 constant SMALL = 1_000 * HKD;
    uint256 constant LARGE = 60_000 * HKD;
    bytes4 constant REASON = "AC04";

    address compliance;
    address adapter = makeAddr("adapter");
    address stranger = makeAddr("stranger");
    bytes32 payee = keccak256("payee at another bank");
    uint256 adviceCount;

    PaymentsHandler handler;

    function setUp() public override {
        super.setUp();
        compliance = _staff("compliance");
        _grantStaff(compliance, Roles.COMPLIANCE);
        handler = new PaymentsHandler(payments, token, compliance, clearingKey, [alice, bob, stranger]);
        targetContract(address(handler));
    }

    /// @dev Over any run of payments in and out, clearing, returning, releasing and rejecting, the
    /// books balance and the module holds exactly the amounts still waiting.
    function invariant_HoldsOnlyWhatIsWaiting() public view {
        assertEq(token.balanceOf(address(payments)), handler.waiting(), "module holds what is waiting");
        _assertBooksBalance();
    }

    function test_ModuleIsABankOwnedBookkeeper() public view {
        assertTrue(token.canTransact(address(payments)));
        assertTrue(_holds(Roles.BOOKKEEPER, address(payments)));
    }

    // Payments in

    function test_In_CreditsTheCustomer() public {
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        uint256 before = token.balanceOf(alice);
        int256 settlement = _settlement();

        vm.expectEmit(address(payments));
        emit Payments.CreditReceived(m.endToEndId, alice, SMALL, Payments.Status.Credited, m.documentHash);
        _receive(m);

        assertEq(token.balanceOf(alice), before + SMALL);
        assertEq(_settlement(), settlement + int256(SMALL));
        assertEq(token.balanceOf(address(payments)), 0);
        _assertBooksBalance();
    }

    function test_In_ForgedAdviceRefused() public {
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        bytes memory forged = _signP256(_key("forger"), payments.hashCreditAdvice(m));
        uint256 supply = token.totalSupply();
        vm.expectRevert(Payments.InvalidPartnerSignature.selector);
        vm.prank(adapter);
        payments.receiveCredit(m, forged);
        assertEq(token.totalSupply(), supply);
    }

    function test_In_AnyFieldChangedRefused() public {
        Payments.CreditAdvice memory signed = _advice(alice, SMALL);
        bytes memory sig = _signP256(clearingKey, payments.hashCreditAdvice(signed));
        for (uint256 field = 0; field < 6; ++field) {
            Payments.CreditAdvice memory m = Payments.CreditAdvice(
                field == 0 ? keccak256("other") : signed.endToEndId,
                field == 1 ? signed.amount + 1 : signed.amount,
                field == 2 ? bytes3("USD") : signed.currency,
                field == 3 ? _account(bob) : signed.creditorAccount,
                field == 4 ? signed.settledAt + 1 : signed.settledAt,
                field == 5 ? keccak256("another document") : signed.documentHash
            );
            vm.expectRevert(Payments.InvalidPartnerSignature.selector);
            payments.receiveCredit(m, sig);
        }
    }

    function test_In_ReplayedAdviceRefused() public {
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        bytes memory sig = _signP256(clearingKey, payments.hashCreditAdvice(m));
        payments.receiveCredit(m, sig);
        uint256 supply = token.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(Payments.ReferenceUsed.selector, m.endToEndId));
        payments.receiveCredit(m, sig);
        assertEq(token.totalSupply(), supply);
    }

    function test_In_OtherDeploymentRefused() public {
        Payments other = new Payments(address(manager), ledger, partnerKeys, SCREENING_THRESHOLD);
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        bytes memory sig = _signP256(clearingKey, other.hashCreditAdvice(m));
        vm.expectRevert(Payments.InvalidPartnerSignature.selector);
        payments.receiveCredit(m, sig);
    }

    function test_In_RevokedKeyRefused() public {
        address itSecurity = _staff("itSecurity");
        _grantStaff(itSecurity, Roles.IT_SECURITY);
        vm.prank(itSecurity);
        partnerKeys.revokeKey(CLEARING);
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        bytes memory sig = _signP256(clearingKey, payments.hashCreditAdvice(m));
        vm.expectRevert(Payments.InvalidPartnerSignature.selector);
        payments.receiveCredit(m, sig);
    }

    function test_In_ZeroRefused() public {
        Payments.CreditAdvice memory m = _advice(alice, 0);
        bytes memory sig = _signP256(clearingKey, payments.hashCreditAdvice(m));
        vm.expectRevert(Payments.ZeroAmount.selector);
        payments.receiveCredit(m, sig);
    }

    // Screening

    function test_Flagged_WaitsInTheModule() public {
        uint256 before = token.balanceOf(alice);
        int256 settlement = _settlement();
        bytes32 ref = _receive(_advice(alice, LARGE));

        assertEq(uint8(payments.incoming(ref).status), uint8(Payments.Status.Screening));
        assertEq(_settlement(), settlement + int256(LARGE), "settlement account rises at once");
        assertEq(token.balanceOf(alice), before, "not on the customer's balance");
        assertEq(token.balanceOf(address(payments)), LARGE);
        _assertBooksBalance();
    }

    function test_Flagged_AtTheThresholdExactly() public {
        bytes32 ref = _receive(_advice(alice, SCREENING_THRESHOLD));
        assertEq(uint8(payments.incoming(ref).status), uint8(Payments.Status.Screening));
    }

    function test_Flagged_ClearedReachesTheCustomer() public {
        uint256 before = token.balanceOf(alice);
        bytes32 ref = _receive(_advice(alice, LARGE));
        vm.prank(compliance);
        payments.clearIncoming(ref);

        assertEq(token.balanceOf(alice), before + LARGE);
        assertEq(token.balanceOf(address(payments)), 0);
        assertEq(uint8(payments.incoming(ref).status), uint8(Payments.Status.Cleared));
        _assertBooksBalance();
    }

    function test_Flagged_ReturnedLeavesTheSettlementAccount() public {
        uint256 before = token.balanceOf(alice);
        int256 settlement = _settlement();
        bytes32 ref = _receive(_advice(alice, LARGE));
        vm.prank(compliance);
        payments.returnIncoming(ref);

        assertEq(token.balanceOf(alice), before, "no customer is credited");
        assertEq(_settlement(), settlement);
        assertEq(token.balanceOf(address(payments)), 0);
        _assertBooksBalance();
    }

    function test_Flagged_ClearedOrReturnedOnce() public {
        bytes32 ref = _receive(_advice(alice, LARGE));
        vm.startPrank(compliance);
        payments.clearIncoming(ref);
        vm.expectRevert(abi.encodeWithSelector(Payments.NotAwaiting.selector, ref, Payments.Status.Cleared));
        payments.clearIncoming(ref);
        vm.expectRevert(abi.encodeWithSelector(Payments.NotAwaiting.selector, ref, Payments.Status.Cleared));
        payments.returnIncoming(ref);
        vm.stopPrank();
    }

    function test_Flagged_OnlyCompliance() public {
        bytes32 ref = _receive(_advice(alice, LARGE));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        payments.clearIncoming(ref);
    }

    function test_Threshold_SetByGovernance() public {
        _govern(address(payments), abi.encodeCall(Payments.setScreeningThreshold, (2 * LARGE)));
        bytes32 ref = _receive(_advice(alice, LARGE));
        assertEq(uint8(payments.incoming(ref).status), uint8(Payments.Status.Credited));
    }

    // Suspense

    function test_Suspense_UnknownBeneficiaryReturned() public {
        _assertSuspenseReturned(_advice(stranger, SMALL));
    }

    function test_Suspense_OtherCurrencyReturned() public {
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        m.currency = "USD";
        _assertSuspenseReturned(m);
    }

    function test_Suspense_AccountWiderThanAnAddressReturned() public {
        Payments.CreditAdvice memory m = _advice(alice, SMALL);
        m.creditorAccount |= bytes32(uint256(1) << 160);
        _assertSuspenseReturned(m);
    }

    function test_Suspense_BlockedCustomer() public {
        vm.prank(compliance);
        token.blockUser(alice);
        _assertSuspenseReturned(_advice(alice, SMALL));
    }

    function test_Suspense_CannotBeCleared() public {
        bytes32 ref = _receive(_advice(stranger, SMALL));
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(Payments.NotAwaiting.selector, ref, Payments.Status.Suspense));
        payments.clearIncoming(ref);
    }

    // Payments out

    function test_Out_QueuedAndReleased() public {
        uint256 before = token.balanceOf(alice);
        int256 settlement = _settlement();
        bytes32 ref = _pay(alice, SMALL);

        assertEq(token.balanceOf(alice), before - SMALL);
        assertEq(token.balanceOf(address(payments)), SMALL);
        assertEq(uint8(payments.outgoing(ref).status), uint8(Payments.Status.Queued));
        _assertBooksBalance();

        vm.expectEmit(address(payments));
        emit Payments.PaymentSent(ref, SMALL);
        vm.prank(stranger);
        assertEq(payments.release(10), 1);

        assertEq(_settlement(), settlement - int256(SMALL));
        assertEq(token.balanceOf(address(payments)), 0);
        assertEq(uint8(payments.outgoing(ref).status), uint8(Payments.Status.Sent));
        _assertBooksBalance();
    }

    function test_Out_FrozenMoneyCannotBeSent() public {
        uint256 balance = token.balanceOf(alice);
        vm.prank(compliance);
        holds.place(alice, balance, Roles.COMPLIANCE, "monitoring");
        vm.startPrank(alice);
        token.approve(address(payments), SMALL);
        vm.expectRevert(abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, alice, SMALL, 0));
        payments.pay(SMALL, payee);
        vm.stopPrank();
    }

    function test_Out_NeedsThePayersApproval() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(payments), 0, SMALL)
        );
        payments.pay(SMALL, payee);
    }

    function test_Out_ZeroRefused() public {
        vm.prank(alice);
        vm.expectRevert(Payments.ZeroAmount.selector);
        payments.pay(0, payee);
    }

    function test_Out_FlaggedWaitsForCompliance() public {
        bytes32 ref = _pay(alice, LARGE);
        assertEq(uint8(payments.outgoing(ref).status), uint8(Payments.Status.Screening));
        assertEq(payments.release(10), 0, "not in the queue");

        vm.prank(compliance);
        payments.clearOutgoing(ref);
        assertEq(payments.release(10), 1);
        assertEq(uint8(payments.outgoing(ref).status), uint8(Payments.Status.Sent));
        _assertBooksBalance();
    }

    function test_Out_FlaggedReturnedToThePayer() public {
        uint256 before = token.balanceOf(alice);
        bytes32 ref = _pay(alice, LARGE);
        vm.prank(compliance);
        payments.returnOutgoing(ref);

        assertEq(token.balanceOf(alice), before);
        assertEq(token.balanceOf(address(payments)), 0);
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(Payments.NotAwaiting.selector, ref, Payments.Status.Returned));
        payments.clearOutgoing(ref);
    }

    function test_Out_SettlementShortQueuesInOrder() public {
        // Treasury buys securities until the settlement account holds less than the first payment.
        _moveSettlement(-(_settlement() - int256(5_000 * HKD)));
        bytes32 first = _pay(alice, 8_000 * HKD);
        bytes32 second = _pay(bob, 1_000 * HKD);

        assertEq(payments.release(10), 0, "the head is not covered, and nothing jumps it");
        assertEq(uint8(payments.outgoing(second).status), uint8(Payments.Status.Queued));

        _moveSettlement(int256(20_000 * HKD));
        assertEq(payments.release(1), 1, "sends no more than asked");
        assertEq(uint8(payments.outgoing(first).status), uint8(Payments.Status.Sent));
        assertEq(payments.release(10), 1);
        assertEq(uint8(payments.outgoing(second).status), uint8(Payments.Status.Sent));
        assertEq(_settlement(), int256(16_000 * HKD));
        _assertBooksBalance();
    }

    // Rejections

    function test_Rejected_BackWhereTheyStarted() public {
        uint256 before = token.balanceOf(alice);
        int256 settlement = _settlement();
        bytes32 ref = _pay(alice, SMALL);
        payments.release(1);

        _reject(ref, SMALL);

        assertEq(token.balanceOf(alice), before);
        assertEq(_settlement(), settlement);
        assertEq(uint8(payments.outgoing(ref).status), uint8(Payments.Status.Rejected));
        _assertBooksBalance();
    }

    function test_Rejected_Once() public {
        bytes32 ref = _pay(alice, SMALL);
        payments.release(1);
        _reject(ref, SMALL);
        _expectRejectionRefused(ref, SMALL);
    }

    function test_Rejected_OnlyWhatWasSent() public {
        bytes32 ref = _pay(alice, LARGE);
        _expectRejectionRefused(ref, LARGE);

        vm.prank(compliance);
        payments.clearOutgoing(ref);
        payments.release(1);
        _expectRejectionRefused(ref, LARGE + 1);
    }

    function test_Rejected_ForgedRefused() public {
        bytes32 ref = _pay(alice, SMALL);
        payments.release(1);
        Payments.PaymentRejection memory m = Payments.PaymentRejection(ref, SMALL, REASON, keccak256("pacs.004"));
        bytes memory forged = _signP256(_key("forger"), payments.hashPaymentRejection(m));
        vm.expectRevert(Payments.InvalidPartnerSignature.selector);
        payments.rejectPayment(m, forged);
    }

    // Helpers

    function _assertSuspenseReturned(Payments.CreditAdvice memory m) private {
        int256 settlement = _settlement();
        uint256 supply = token.totalSupply();
        bytes32 ref = _receive(m);
        assertEq(uint8(payments.incoming(ref).status), uint8(Payments.Status.Suspense));
        assertEq(token.balanceOf(address(payments)), m.amount, "waits in suspense");
        assertEq(token.totalSupply(), supply + m.amount, "no customer is credited");

        vm.prank(compliance);
        payments.returnIncoming(ref);
        assertEq(token.balanceOf(address(payments)), 0, "suspense is empty after the return");
        assertEq(token.totalSupply(), supply);
        assertEq(_settlement(), settlement);
        _assertBooksBalance();
    }

    function _advice(address to, uint256 amount) private returns (Payments.CreditAdvice memory) {
        return
            Payments.CreditAdvice(
                keccak256(abi.encode("E2E", ++adviceCount)),
                amount,
                "HKD",
                _account(to),
                block.timestamp,
                keccak256(abi.encode("camt.054", adviceCount))
            );
    }

    function _receive(Payments.CreditAdvice memory m) private returns (bytes32) {
        bytes memory sig = _signP256(clearingKey, payments.hashCreditAdvice(m));
        vm.prank(adapter);
        payments.receiveCredit(m, sig);
        return m.endToEndId;
    }

    function _pay(address from, uint256 amount) private returns (bytes32 ref) {
        vm.startPrank(from);
        token.approve(address(payments), amount);
        ref = payments.pay(amount, payee);
        vm.stopPrank();
    }

    function _reject(bytes32 ref, uint256 amount) private {
        (Payments.PaymentRejection memory m, bytes memory sig) = _rejection(ref, amount);
        vm.prank(adapter);
        payments.rejectPayment(m, sig);
    }

    function _expectRejectionRefused(bytes32 ref, uint256 amount) private {
        (Payments.PaymentRejection memory m, bytes memory sig) = _rejection(ref, amount);
        vm.expectRevert(abi.encodeWithSelector(Payments.UnknownPayment.selector, ref, amount));
        payments.rejectPayment(m, sig);
    }

    function _rejection(
        bytes32 ref,
        uint256 amount
    ) private view returns (Payments.PaymentRejection memory m, bytes memory sig) {
        m = Payments.PaymentRejection(ref, amount, REASON, keccak256("pacs.004"));
        sig = _signP256(clearingKey, payments.hashPaymentRejection(m));
    }

    function _settlement() private view returns (int256) {
        return ledger.balanceOf(GeneralLedger.Account.Settlement);
    }

    function _account(address a) private pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}

/// @dev Runs payments in and out for two customers and a stranger, with compliance clearing and
/// returning and the clearing system rejecting, in any order, and keeps the total still waiting.
contract PaymentsHandler is Test {
    Payments immutable payments;
    DepositToken immutable token;
    address immutable compliance;
    uint256 immutable clearingKey;
    address[3] parties;

    bytes32[] incomingRefs;
    bytes32[] outgoingRefs;
    uint256 public waiting;

    constructor(
        Payments payments_,
        DepositToken token_,
        address compliance_,
        uint256 clearingKey_,
        address[3] memory parties_
    ) {
        payments = payments_;
        token = token_;
        compliance = compliance_;
        clearingKey = clearingKey_;
        parties = parties_;
    }

    function receiveCredit(uint256 party, uint256 amount, bool otherCurrency) external {
        amount = bound(amount, 1, 4 * payments.screeningThreshold());
        Payments.CreditAdvice memory m = Payments.CreditAdvice(
            keccak256(abi.encode("handler", incomingRefs.length)),
            amount,
            otherCurrency ? bytes3("USD") : payments.HKD(),
            bytes32(uint256(uint160(parties[bound(party, 0, 2)]))),
            block.timestamp,
            bytes32(0)
        );
        payments.receiveCredit(m, _sign(payments.hashCreditAdvice(m)));
        incomingRefs.push(m.endToEndId);
        if (payments.incoming(m.endToEndId).status != Payments.Status.Credited) waiting += amount;
    }

    function clearIncoming(uint256 index) external {
        bytes32 ref = _pick(incomingRefs, index);
        Payments.Payment memory p = payments.incoming(ref);
        if (p.status != Payments.Status.Screening) return;
        vm.prank(compliance);
        payments.clearIncoming(ref);
        waiting -= p.amount;
    }

    function returnIncoming(uint256 index) external {
        bytes32 ref = _pick(incomingRefs, index);
        Payments.Payment memory p = payments.incoming(ref);
        if (p.status != Payments.Status.Screening && p.status != Payments.Status.Suspense) return;
        vm.prank(compliance);
        payments.returnIncoming(ref);
        waiting -= p.amount;
    }

    function pay(bool second, uint256 amount) external {
        address payer = parties[second ? 1 : 0];
        uint256 balance = token.balanceOf(payer);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.startPrank(payer);
        token.approve(address(payments), amount);
        outgoingRefs.push(payments.pay(amount, bytes32(0)));
        vm.stopPrank();
        waiting += amount;
    }

    function clearOutgoing(uint256 index) external {
        bytes32 ref = _pick(outgoingRefs, index);
        if (payments.outgoing(ref).status != Payments.Status.Screening) return;
        vm.prank(compliance);
        payments.clearOutgoing(ref);
    }

    function returnOutgoing(uint256 index) external {
        bytes32 ref = _pick(outgoingRefs, index);
        Payments.Payment memory p = payments.outgoing(ref);
        if (p.status != Payments.Status.Screening) return;
        vm.prank(compliance);
        payments.returnOutgoing(ref);
        waiting -= p.amount;
    }

    function release(uint256 max) external {
        uint256 head = payments.queueHead();
        uint256 sent = payments.release(bound(max, 0, 5));
        for (uint256 i = head; i < head + sent; ++i) waiting -= payments.outgoing(payments.queue(i)).amount;
    }

    function reject(uint256 index) external {
        bytes32 ref = _pick(outgoingRefs, index);
        Payments.Payment memory p = payments.outgoing(ref);
        if (p.status != Payments.Status.Sent) return;
        Payments.PaymentRejection memory m = Payments.PaymentRejection(ref, p.amount, "AC04", bytes32(0));
        payments.rejectPayment(m, _sign(payments.hashPaymentRejection(m)));
    }

    function _pick(bytes32[] storage refs, uint256 index) private view returns (bytes32) {
        return refs.length == 0 ? bytes32(0) : refs[bound(index, 0, refs.length - 1)];
    }

    /// @dev As the fixture's _signP256, which this contract does not inherit.
    function _sign(bytes32 digest) private view returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(clearingKey, digest);
        if (uint256(s) > P256.N / 2) s = bytes32(P256.N - uint256(s));
        return abi.encodePacked(r, s);
    }
}
