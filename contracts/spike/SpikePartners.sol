// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @dev Partner keys spike: the register of the outside parties' signing keys. Each key is kept in
/// ERC-7913 form, a verifier's address followed by the key, so a partner signing with P-256 or RSA
/// is registered the same way and no partner needs an account on the chain. Plain Ethereum keys
/// are refused: no clearing system holds one. See open question 12 in docs/plan.md.
contract SpikePartnerKeys is AccessManaged {
    mapping(bytes32 partner => bytes signer) private _keys;

    event KeySet(bytes32 indexed partner, bytes signer);
    event KeyRevoked(bytes32 indexed partner);

    error NotAVerifierKey(bytes signer);

    constructor(address manager) AccessManaged(manager) {}

    function keyOf(bytes32 partner) external view returns (bytes memory) {
        return _keys[partner];
    }

    /// @dev A verifier with no code would make every check fail and lock the partner out unseen.
    function setKey(bytes32 partner, bytes calldata signer) external restricted {
        if (signer.length <= 20 || address(bytes20(signer[:20])).code.length == 0) revert NotAVerifierKey(signer);
        _keys[partner] = signer;
        emit KeySet(partner, signer);
    }

    /// @dev For a compromised key: takes effect at once, with no waiting period.
    function revokeKey(bytes32 partner) external restricted {
        delete _keys[partner];
        emit KeyRevoked(partner);
    }

    function verify(bytes32 partner, bytes32 digest, bytes calldata signature) public view returns (bool) {
        bytes memory signer = _keys[partner];
        return signer.length != 0 && SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }
}

/// @dev Payments spike: the clearing system's signed messages as EIP-712 structs. The chain cannot
/// read the ISO 20022 XML, so each struct carries only the fields the contract acts on, named after
/// their ISO 20022 counterparts, and the hash of the whole document so the indexer can match the
/// two. The domain names this contract and chain, so a message signed for another deployment is
/// refused. Anyone may relay a message: its authority is the partner's signature alone.
contract SpikePayments is EIP712, AccessManaged {
    bytes32 public constant CLEARING = keccak256("clearing");

    /// @dev camt.054: the clearing system has credited the bank's settlement account for a customer.
    struct CreditAdvice {
        bytes32 endToEndId;
        uint256 amount;
        bytes3 currency;
        bytes32 creditorAccount;
        uint256 settledAt;
        bytes32 documentHash;
    }

    /// @dev pacs.002 rejection or pacs.004 return of a payment the bank sent.
    struct PaymentRejection {
        bytes32 originalEndToEndId;
        uint256 amount;
        bytes4 reasonCode;
        bytes32 documentHash;
    }

    /// @dev camt.053: the settlement account's closing balance at the end of a statement period.
    struct Statement {
        bytes32 statementId;
        uint256 sequence;
        uint256 closingBalance;
        uint256 asOf;
        bytes32 documentHash;
    }

    bytes32 private constant CREDIT_ADVICE_TYPEHASH =
        keccak256(
            "CreditAdvice(bytes32 endToEndId,uint256 amount,bytes3 currency,bytes32 creditorAccount,uint256 settledAt,bytes32 documentHash)"
        );
    bytes32 private constant PAYMENT_REJECTION_TYPEHASH =
        keccak256("PaymentRejection(bytes32 originalEndToEndId,uint256 amount,bytes4 reasonCode,bytes32 documentHash)");
    bytes32 private constant STATEMENT_TYPEHASH =
        keccak256(
            "Statement(bytes32 statementId,uint256 sequence,uint256 closingBalance,uint256 asOf,bytes32 documentHash)"
        );

    SpikePartnerKeys public immutable partners;

    mapping(bytes32 endToEndId => bool) public credited;
    mapping(bytes32 creditorAccount => uint256) public creditedTo;
    mapping(bytes32 endToEndId => uint256) public sentOut;
    uint256 public statementSequence;
    uint256 public settlementBalance;
    uint256 public settlementAsOf;

    event CreditReceived(bytes32 indexed endToEndId, bytes32 indexed creditorAccount, uint256 amount, bytes32 documentHash);
    event PaymentReturned(bytes32 indexed endToEndId, uint256 amount, bytes4 reasonCode, bytes32 documentHash);
    event StatementAccepted(bytes32 indexed statementId, uint256 sequence, uint256 closingBalance, bytes32 documentHash);

    error InvalidPartnerSignature();
    error ReferenceUsed(bytes32 endToEndId);
    error UnknownPayment(bytes32 endToEndId, uint256 amount);
    error StaleStatement(uint256 sequence, uint256 latest);

    constructor(address manager, SpikePartnerKeys partners_) EIP712("Spike Payments", "1") AccessManaged(manager) {
        partners = partners_;
    }

    function hashCreditAdvice(CreditAdvice calldata m) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        CREDIT_ADVICE_TYPEHASH,
                        m.endToEndId,
                        m.amount,
                        m.currency,
                        m.creditorAccount,
                        m.settledAt,
                        m.documentHash
                    )
                )
            );
    }

    function hashPaymentRejection(PaymentRejection calldata m) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(abi.encode(PAYMENT_REJECTION_TYPEHASH, m.originalEndToEndId, m.amount, m.reasonCode, m.documentHash))
            );
    }

    function hashStatement(Statement calldata m) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(STATEMENT_TYPEHASH, m.statementId, m.sequence, m.closingBalance, m.asOf, m.documentHash)
                )
            );
    }

    /// @dev Stands in for the payment out flow, which ends with the message to the clearing system.
    function sendOut(bytes32 endToEndId, uint256 amount) external restricted {
        sentOut[endToEndId] = amount;
    }

    /// @dev In the full design this matches the beneficiary and creates deposit tokens through the ledger.
    function creditIn(CreditAdvice calldata m, bytes calldata signature) external {
        _checkSignature(hashCreditAdvice(m), signature);
        if (credited[m.endToEndId]) revert ReferenceUsed(m.endToEndId);
        credited[m.endToEndId] = true;
        creditedTo[m.creditorAccount] += m.amount;
        emit CreditReceived(m.endToEndId, m.creditorAccount, m.amount, m.documentHash);
    }

    /// @dev Accepted once per payment sent, and only for its amount: the record is cleared on use.
    function rejectOut(PaymentRejection calldata m, bytes calldata signature) external {
        _checkSignature(hashPaymentRejection(m), signature);
        if (m.amount == 0 || sentOut[m.originalEndToEndId] != m.amount) {
            revert UnknownPayment(m.originalEndToEndId, m.amount);
        }
        delete sentOut[m.originalEndToEndId];
        emit PaymentReturned(m.originalEndToEndId, m.amount, m.reasonCode, m.documentHash);
    }

    /// @dev Statements are accepted in order only, so an old one cannot be replayed over a newer figure.
    /// A number may be skipped: a statement that never arrived is superseded by the next.
    function acceptStatement(Statement calldata m, bytes calldata signature) external {
        _checkSignature(hashStatement(m), signature);
        if (m.sequence <= statementSequence) revert StaleStatement(m.sequence, statementSequence);
        statementSequence = m.sequence;
        settlementBalance = m.closingBalance;
        settlementAsOf = m.asOf;
        emit StatementAccepted(m.statementId, m.sequence, m.closingBalance, m.documentHash);
    }

    function _checkSignature(bytes32 digest, bytes calldata signature) private view {
        if (!partners.verify(CLEARING, digest, signature)) revert InvalidPartnerSignature();
    }
}
