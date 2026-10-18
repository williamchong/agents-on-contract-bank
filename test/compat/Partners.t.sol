// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {ERC7913P256Verifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol";
import {ERC7913RSAVerifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913RSAVerifier.sol";
import {SpikePartnerKeys, SpikePayments} from "../../contracts/spike/SpikePartners.sol";
import {RsaVector} from "../RsaVector.sol";

/// @dev Checks that the clearing system's signed messages are accepted only under its registered
/// key, only as signed, only for this deployment and only once, and that a key can be rotated or
/// revoked. Covers the forged credit advice scenario in docs/scenarios.md. Run with --gas-stats, or
/// read test_Gas_VerifyByKeyType's log, to compare key types. See open question 12 in docs/plan.md.
contract PartnersTest is Test {
    uint64 constant GOVERNANCE = 1;
    uint64 constant IT_SECURITY = 2;

    bytes32 constant CLEARING = keccak256("clearing");
    bytes32 constant RSA_PARTNER = keccak256("rsa partner");

    AccessManager manager;
    SpikePartnerKeys keys;
    SpikePayments payments;
    ERC7913P256Verifier p256Verifier;
    ERC7913RSAVerifier rsaVerifier;

    uint256 clearingKey = 0xC1EA;
    uint256 otherKey = 0x0BAD;
    address governance = makeAddr("governance");
    address security = makeAddr("security");
    address adapter = makeAddr("adapter");
    address bob = makeAddr("bob");

    function setUp() public {
        manager = new AccessManager(address(this));
        keys = new SpikePartnerKeys(address(manager));
        payments = new SpikePayments(address(manager), keys);
        p256Verifier = new ERC7913P256Verifier();
        rsaVerifier = new ERC7913RSAVerifier();

        _setRole(keys.setKey.selector, GOVERNANCE);
        _setRole(keys.revokeKey.selector, IT_SECURITY);
        manager.grantRole(GOVERNANCE, governance, 0);
        manager.grantRole(IT_SECURITY, security, 0);

        vm.prank(governance);
        keys.setKey(CLEARING, _p256Signer(clearingKey));
    }

    // Credit advices

    function test_CreditAdvice_AcceptedFromAnyRelay() public {
        SpikePayments.CreditAdvice memory m = _advice();
        bytes memory sig = _sign(clearingKey, payments.hashCreditAdvice(m));

        vm.expectEmit(address(payments));
        emit SpikePayments.CreditReceived(m.endToEndId, m.creditorAccount, m.amount, m.documentHash);
        vm.prank(adapter);
        payments.creditIn(m, sig);

        assertTrue(payments.credited(m.endToEndId));
        assertEq(payments.creditedTo(m.creditorAccount), m.amount);
    }

    function test_CreditAdvice_AnyFieldChangedRefused() public {
        bytes memory sig = _sign(clearingKey, payments.hashCreditAdvice(_advice()));
        for (uint256 field = 0; field < 6; ++field) {
            SpikePayments.CreditAdvice memory m = _advice();
            if (field == 0) m.endToEndId = keccak256("E2E-2");
            if (field == 1) m.amount += 1;
            if (field == 2) m.currency = "USD";
            if (field == 3) m.creditorAccount = keccak256("account 2");
            if (field == 4) m.settledAt += 1;
            if (field == 5) m.documentHash = keccak256("another document");

            vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
            payments.creditIn(m, sig);
        }
    }

    function test_CreditAdvice_UnregisteredKeyRefused() public {
        SpikePayments.CreditAdvice memory m = _advice();
        bytes memory sig = _sign(otherKey, payments.hashCreditAdvice(m));

        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.creditIn(m, sig);
        assertEq(payments.creditedTo(m.creditorAccount), 0);
    }

    function test_CreditAdvice_HighSFormRefused() public {
        SpikePayments.CreditAdvice memory m = _advice();
        (bytes32 r, bytes32 s) = abi.decode(_sign(clearingKey, payments.hashCreditAdvice(m)), (bytes32, bytes32));
        bytes memory highS = abi.encodePacked(r, bytes32(P256.N - uint256(s)));

        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.creditIn(m, highS);
    }

    function test_CreditAdvice_ReplayRefused() public {
        SpikePayments.CreditAdvice memory m = _advice();
        bytes memory sig = _sign(clearingKey, payments.hashCreditAdvice(m));
        payments.creditIn(m, sig);

        vm.expectRevert(abi.encodeWithSelector(SpikePayments.ReferenceUsed.selector, m.endToEndId));
        payments.creditIn(m, sig);
        assertEq(payments.creditedTo(m.creditorAccount), m.amount);
    }

    function test_CreditAdvice_ForAnotherDeploymentRefused() public {
        SpikePayments other = new SpikePayments(address(manager), keys);
        SpikePayments.CreditAdvice memory m = _advice();
        bytes memory sig = _sign(clearingKey, other.hashCreditAdvice(m));

        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.creditIn(m, sig);
    }

    // Rejections and statements

    function test_Rejection_ReturnsPaymentOnce() public {
        SpikePayments.PaymentRejection memory m = _rejection();
        payments.sendOut(m.originalEndToEndId, m.amount);
        bytes memory sig = _sign(clearingKey, payments.hashPaymentRejection(m));

        vm.expectEmit(address(payments));
        emit SpikePayments.PaymentReturned(m.originalEndToEndId, m.amount, m.reasonCode, m.documentHash);
        payments.rejectOut(m, sig);
        assertEq(payments.sentOut(m.originalEndToEndId), 0);

        vm.expectRevert(
            abi.encodeWithSelector(SpikePayments.UnknownPayment.selector, m.originalEndToEndId, m.amount)
        );
        payments.rejectOut(m, sig);
    }

    function test_Rejection_OtherAmountRefused() public {
        SpikePayments.PaymentRejection memory m = _rejection();
        payments.sendOut(m.originalEndToEndId, m.amount - 1);
        bytes memory sig = _sign(clearingKey, payments.hashPaymentRejection(m));

        vm.expectRevert(
            abi.encodeWithSelector(SpikePayments.UnknownPayment.selector, m.originalEndToEndId, m.amount)
        );
        payments.rejectOut(m, sig);
    }

    function test_Rejection_UnsentPaymentRefused() public {
        SpikePayments.PaymentRejection memory m = _rejection();
        m.amount = 0;
        bytes memory sig = _sign(clearingKey, payments.hashPaymentRejection(m));

        vm.expectRevert(abi.encodeWithSelector(SpikePayments.UnknownPayment.selector, m.originalEndToEndId, 0));
        payments.rejectOut(m, sig);
    }

    function test_RejectionAndStatement_UnregisteredKeyRefused() public {
        SpikePayments.PaymentRejection memory rejection = _rejection();
        payments.sendOut(rejection.originalEndToEndId, rejection.amount);
        bytes memory sig = _sign(otherKey, payments.hashPaymentRejection(rejection));
        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.rejectOut(rejection, sig);

        SpikePayments.Statement memory statement = _statement(1, 1_000);
        sig = _sign(otherKey, payments.hashStatement(statement));
        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.acceptStatement(statement, sig);

        assertEq(payments.sentOut(rejection.originalEndToEndId), rejection.amount);
        assertEq(payments.statementSequence(), 0);
    }

    function test_Statement_AcceptedInOrderOnly() public {
        SpikePayments.Statement memory first = _statement(2, 1_000);
        vm.expectEmit(address(payments));
        emit SpikePayments.StatementAccepted(first.statementId, 2, 1_000, first.documentHash);
        payments.acceptStatement(first, _sign(clearingKey, payments.hashStatement(first)));
        assertEq(payments.settlementBalance(), 1_000);
        assertEq(payments.settlementAsOf(), first.asOf);

        SpikePayments.Statement memory again = _statement(2, 2_000);
        bytes memory sig = _sign(clearingKey, payments.hashStatement(again));
        vm.expectRevert(abi.encodeWithSelector(SpikePayments.StaleStatement.selector, 2, 2));
        payments.acceptStatement(again, sig);

        SpikePayments.Statement memory older = _statement(1, 3_000);
        sig = _sign(clearingKey, payments.hashStatement(older));
        vm.expectRevert(abi.encodeWithSelector(SpikePayments.StaleStatement.selector, 1, 2));
        payments.acceptStatement(older, sig);

        assertEq(payments.settlementBalance(), 1_000);
    }

    // Partner keys

    function test_Rotation_OldKeyRefused() public {
        uint256 newKey = 0xC1EA2;
        vm.prank(governance);
        keys.setKey(CLEARING, _p256Signer(newKey));

        SpikePayments.CreditAdvice memory m = _advice();
        bytes memory oldSig = _sign(clearingKey, payments.hashCreditAdvice(m));
        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.creditIn(m, oldSig);

        payments.creditIn(m, _sign(newKey, payments.hashCreditAdvice(m)));
        assertEq(payments.creditedTo(m.creditorAccount), m.amount);
    }

    function test_Revoke_RefusesEveryMessage() public {
        vm.prank(security);
        keys.revokeKey(CLEARING);

        SpikePayments.CreditAdvice memory m = _advice();
        bytes memory sig = _sign(clearingKey, payments.hashCreditAdvice(m));
        vm.expectRevert(SpikePayments.InvalidPartnerSignature.selector);
        payments.creditIn(m, sig);
    }

    function test_SetKey_OnlyGovernance() public {
        bytes memory signer = _p256Signer(otherKey);
        vm.prank(security);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, security));
        keys.setKey(CLEARING, signer);
    }

    function test_RevokeKey_OnlyItSecurity() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, governance));
        keys.revokeKey(CLEARING);
    }

    function test_SetKey_VerifierWithoutCodeRefused() public {
        bytes memory signer = abi.encodePacked(makeAddr("no verifier"), bytes32(0), bytes32(0));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SpikePartnerKeys.NotAVerifierKey.selector, signer));
        keys.setKey(CLEARING, signer);
    }

    function test_SetKey_PlainEthereumKeyRefused() public {
        bytes memory signer = abi.encodePacked(vm.addr(otherKey));
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(SpikePartnerKeys.NotAVerifierKey.selector, signer));
        keys.setKey(CLEARING, signer);
    }

    function test_Rsa_FixedVectorVerifies() public {
        vm.prank(governance);
        keys.setKey(RSA_PARTNER, _rsaSigner());
        bytes32 digest = RsaVector.DIGEST;

        assertTrue(keys.verify(RSA_PARTNER, digest, RsaVector.SIG));

        bytes memory flipped = RsaVector.SIG;
        flipped[255] ^= 0x01;
        assertFalse(keys.verify(RSA_PARTNER, digest, flipped));
        assertFalse(keys.verify(RSA_PARTNER, keccak256("another digest"), RsaVector.SIG));
    }

    // Cost

    /// @dev Logs what one signature check through the register costs for each key type, whether this
    /// chain has the P-256 precompile that Base also has, and what P-256 costs without it.
    function test_Gas_VerifyByKeyType() public {
        vm.prank(governance);
        keys.setKey(RSA_PARTNER, _rsaSigner());
        bytes32 digest = RsaVector.DIGEST;
        bytes memory p256Sig = _sign(clearingKey, digest);

        uint256 before = gasleft();
        assertTrue(keys.verify(CLEARING, digest, p256Sig));
        uint256 p256Gas = before - gasleft();

        before = gasleft();
        assertTrue(keys.verify(RSA_PARTNER, digest, RsaVector.SIG));
        uint256 rsaGas = before - gasleft();

        (uint256 x, uint256 y) = vm.publicKeyP256(clearingKey);
        (bytes32 r, bytes32 s) = abi.decode(p256Sig, (bytes32, bytes32));
        before = gasleft();
        assertTrue(P256.verifySolidity(digest, r, s, bytes32(x), bytes32(y)));
        uint256 fallbackGas = before - gasleft();

        (bool ok, bytes memory out) = address(0x100).staticcall(abi.encodePacked(digest, p256Sig, x, y));
        console.log("P-256 precompile present:", ok && out.length == 32);
        console.log("P-256 verify gas:", p256Gas);
        console.log("P-256 Solidity fallback gas, check only:", fallbackGas);
        console.log("RSA-2048 verify gas:", rsaGas);
    }

    // Helpers

    function _setRole(bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(address(keys), selectors, role);
    }

    function _p256Signer(uint256 key) private view returns (bytes memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        return abi.encodePacked(address(p256Verifier), x, y);
    }

    function _rsaSigner() private view returns (bytes memory) {
        return abi.encodePacked(address(rsaVerifier), abi.encode(RsaVector.E, RsaVector.N));
    }

    /// @dev P-256 signatures are accepted only in their low-s form, so the high form is folded down.
    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (bytes32 r, bytes32 s) = vm.signP256(key, digest);
        if (uint256(s) > P256.N / 2) s = bytes32(P256.N - uint256(s));
        return abi.encodePacked(r, s);
    }

    function _advice() private pure returns (SpikePayments.CreditAdvice memory) {
        return
            SpikePayments.CreditAdvice({
                endToEndId: keccak256("E2E-1"),
                amount: 25_000,
                currency: "HKD",
                creditorAccount: keccak256("account 1"),
                settledAt: 1_700_000_000,
                documentHash: keccak256("camt.054 document")
            });
    }

    function _rejection() private pure returns (SpikePayments.PaymentRejection memory) {
        return
            SpikePayments.PaymentRejection({
                originalEndToEndId: keccak256("E2E-OUT-1"),
                amount: 40_000,
                reasonCode: "AC01",
                documentHash: keccak256("pacs.002 document")
            });
    }

    function _statement(uint256 sequence, uint256 closingBalance) private pure returns (SpikePayments.Statement memory) {
        return
            SpikePayments.Statement({
                statementId: keccak256(abi.encode("STMT", sequence)),
                sequence: sequence,
                closingBalance: closingBalance,
                asOf: 1_700_000_000 + sequence,
                documentHash: keccak256("camt.053 document")
            });
    }
}
