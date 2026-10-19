// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DepositToken} from "./DepositToken.sol";
import {GeneralLedger} from "./GeneralLedger.sol";
import {PartnerKeys} from "./PartnerKeys.sol";

/// @dev The payments module: payments in by the clearing system's signed credit advice, payments out
/// by the payer's own call, and the money in waiting between. It is a bank-owned account on the
/// allow-list holding the bookkeeper role, and keeps each amount it holds against its payment's
/// reference, so the amount can only reach that payment's beneficiary, go back where it came from,
/// or leave through the clearing system. Screening on chain is a single threshold: a payment at or
/// above it waits here for compliance. Every step moves the settlement account and deposits
/// together, or moves tokens between the module and a customer, so the books balance throughout.
/// The clearing system's messages are EIP-712 structs of the fields acted on plus the document's
/// hash; anyone may relay one, as its authority is the signature alone. See open questions 12 and
/// 14 in docs/plan.md.
contract Payments is EIP712, AccessManaged {
    using SafeCast for uint256;
    using SafeCast for int256;

    bytes32 public constant CLEARING = keccak256("clearing");
    bytes3 public constant HKD = "HKD";

    enum Status {
        None,
        Credited,
        Screening,
        Suspense,
        Cleared,
        Queued,
        Sent,
        Returned,
        Rejected
    }

    /// @dev `party` is the beneficiary of a payment in, or the payer of a payment out.
    struct Payment {
        address party;
        uint256 amount;
        Status status;
    }

    /// @dev camt.054: the clearing system has credited the bank's settlement account for a customer,
    /// whose address is the creditor account.
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

    bytes32 private constant CREDIT_ADVICE_TYPEHASH =
        keccak256(
            "CreditAdvice(bytes32 endToEndId,uint256 amount,bytes3 currency,bytes32 creditorAccount,uint256 settledAt,bytes32 documentHash)"
        );
    bytes32 private constant PAYMENT_REJECTION_TYPEHASH =
        keccak256("PaymentRejection(bytes32 originalEndToEndId,uint256 amount,bytes4 reasonCode,bytes32 documentHash)");

    GeneralLedger public immutable ledger;
    DepositToken public immutable token;
    PartnerKeys public immutable partners;

    uint256 public screeningThreshold;
    uint256 public orderCount;
    /// @dev Payments out cleared to leave, released strictly in order from `queueHead`.
    uint256 public queueHead;
    uint256 public queueTail;
    mapping(uint256 position => bytes32 ref) public queue;
    mapping(bytes32 ref => Payment) private _incoming;
    mapping(bytes32 ref => Payment) private _outgoing;

    event CreditReceived(
        bytes32 indexed ref,
        address indexed beneficiary,
        uint256 amount,
        Status status,
        bytes32 documentHash
    );
    event IncomingCleared(bytes32 indexed ref, address indexed beneficiary, uint256 amount);
    event IncomingReturned(bytes32 indexed ref, uint256 amount);
    event PaymentOrdered(bytes32 indexed ref, address indexed payer, uint256 amount, bytes32 payeeHash, Status status);
    event PaymentQueued(bytes32 indexed ref);
    event PaymentSent(bytes32 indexed ref, uint256 amount);
    event PaymentReturned(bytes32 indexed ref, address indexed payer, uint256 amount);
    event PaymentRejected(bytes32 indexed ref, address indexed payer, uint256 amount, bytes4 reasonCode, bytes32 documentHash);
    event ScreeningThresholdSet(uint256 amount);

    error InvalidPartnerSignature();
    error ReferenceUsed(bytes32 ref);
    error UnknownPayment(bytes32 ref, uint256 amount);
    error NotAwaiting(bytes32 ref, Status status);
    error ZeroAmount();

    constructor(
        address manager,
        GeneralLedger ledger_,
        PartnerKeys partners_,
        uint256 screeningThreshold_
    ) EIP712("Payments", "1") AccessManaged(manager) {
        ledger = ledger_;
        token = ledger_.token();
        partners = partners_;
        screeningThreshold = screeningThreshold_;
    }

    function incoming(bytes32 ref) external view returns (Payment memory) {
        return _incoming[ref];
    }

    function outgoing(bytes32 ref) external view returns (Payment memory) {
        return _outgoing[ref];
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

    function setScreeningThreshold(uint256 amount) external restricted {
        screeningThreshold = amount;
        emit ScreeningThresholdSet(amount);
    }

    // Payments in

    /// @dev The clearing system has already credited the settlement account, so deposits are created
    /// against it at once. A clean payment is created for its beneficiary. One for an address the
    /// token does not admit, or in another currency, is created for the module as suspense and can
    /// only be returned; one at or above the screening threshold is created for the module to wait
    /// for compliance.
    function receiveCredit(CreditAdvice calldata m, bytes calldata signature) external {
        _checkSignature(hashCreditAdvice(m), signature);
        if (m.amount == 0) revert ZeroAmount();
        if (_incoming[m.endToEndId].status != Status.None) revert ReferenceUsed(m.endToEndId);

        address beneficiary = _addressOf(m.creditorAccount);
        Status status;
        if (m.currency != HKD || beneficiary == address(0) || !token.canTransact(beneficiary)) {
            status = Status.Suspense;
        } else if (m.amount >= screeningThreshold) {
            status = Status.Screening;
        } else {
            status = Status.Credited;
        }
        _incoming[m.endToEndId] = Payment(beneficiary, m.amount, status);
        _postMint(status == Status.Credited ? beneficiary : address(this), m.amount, m.endToEndId);
        emit CreditReceived(m.endToEndId, beneficiary, m.amount, status, m.documentHash);
    }

    /// @dev Compliance passes a screened payment in to its beneficiary.
    function clearIncoming(bytes32 ref) external restricted {
        Payment storage p = _awaiting(_incoming, ref, Status.Screening);
        p.status = Status.Cleared;
        token.transfer(p.party, p.amount);
        emit IncomingCleared(ref, p.party, p.amount);
    }

    /// @dev Compliance sends a screened or suspense payment back to its sender: the clearing system
    /// takes it from the settlement account, and the deposits are destroyed with it.
    function returnIncoming(bytes32 ref) external restricted {
        Payment storage p = _incoming[ref];
        if (p.status != Status.Screening && p.status != Status.Suspense) revert NotAwaiting(ref, p.status);
        p.status = Status.Returned;
        _postBurn(p.amount, ref);
        emit IncomingReturned(ref, p.amount);
    }

    // Payments out

    /// @dev The payer's own call: the amount moves from the payer to the module, which the payer has
    /// approved in the same batch, so frozen money cannot be sent. `payeeHash` stands for the payee's
    /// details, which stay with the bank's systems. Below the screening threshold the payment joins
    /// the queue at once.
    function pay(uint256 amount, bytes32 payeeHash) external returns (bytes32 ref) {
        if (amount == 0) revert ZeroAmount();
        ref = keccak256(abi.encode(block.chainid, address(this), ++orderCount));
        Status status = amount >= screeningThreshold ? Status.Screening : Status.Queued;
        _outgoing[ref] = Payment(msg.sender, amount, status);
        token.transferFrom(msg.sender, address(this), amount);
        emit PaymentOrdered(ref, msg.sender, amount, payeeHash, status);
        if (status == Status.Queued) _enqueue(ref);
    }

    /// @dev Compliance lets a screened payment out join the queue.
    function clearOutgoing(bytes32 ref) external restricted {
        _awaiting(_outgoing, ref, Status.Screening).status = Status.Queued;
        _enqueue(ref);
    }

    /// @dev Compliance stops a screened payment out and gives the money back to its payer.
    function returnOutgoing(bytes32 ref) external restricted {
        Payment storage p = _awaiting(_outgoing, ref, Status.Screening);
        p.status = Status.Returned;
        token.transfer(p.party, p.amount);
        emit PaymentReturned(ref, p.party, p.amount);
    }

    /// @dev Sends up to `max` payments from the head of the queue while the settlement account covers
    /// each, and stops at the first it does not, so payments leave in order. Anyone may call it: it
    /// chooses nothing. Returns how many were sent.
    function release(uint256 max) external returns (uint256 sent) {
        uint256 head = queueHead;
        // Only this loop's own postings move the settlement account meanwhile.
        int256 settlement = ledger.balanceOf(GeneralLedger.Account.Settlement);
        while (sent < max && head < queueTail) {
            bytes32 ref = queue[head];
            Payment storage p = _outgoing[ref];
            uint256 amount = p.amount;
            if (settlement < amount.toInt256()) break;
            settlement -= amount.toInt256();
            ++head;
            ++sent;
            p.status = Status.Sent;
            _postBurn(amount, ref);
            emit PaymentSent(ref, amount);
        }
        queueHead = head;
    }

    /// @dev The receiving bank refused a payment sent: the clearing system has put the amount back in
    /// the settlement account, so the deposits are created for the payer again. Accepted once per
    /// payment, and only for its amount. A payer blocked since paying cannot receive it, so the
    /// rejection waits until compliance lifts the block.
    function rejectPayment(PaymentRejection calldata m, bytes calldata signature) external {
        _checkSignature(hashPaymentRejection(m), signature);
        Payment storage p = _outgoing[m.originalEndToEndId];
        if (p.status != Status.Sent || p.amount != m.amount) revert UnknownPayment(m.originalEndToEndId, m.amount);
        p.status = Status.Rejected;
        _postMint(p.party, p.amount, m.originalEndToEndId);
        emit PaymentRejected(m.originalEndToEndId, p.party, p.amount, m.reasonCode, m.documentHash);
    }

    // Internal

    function _enqueue(bytes32 ref) private {
        queue[queueTail++] = ref;
        emit PaymentQueued(ref);
    }

    function _awaiting(
        mapping(bytes32 => Payment) storage payments,
        bytes32 ref,
        Status status
    ) private view returns (Payment storage p) {
        p = payments[ref];
        if (p.status != status) revert NotAwaiting(ref, p.status);
    }

    function _postMint(address to, uint256 amount, bytes32 ref) private {
        ledger.postWithMint(to, amount, _settlement(amount.toInt256().toInt128()), ref);
    }

    function _postBurn(uint256 amount, bytes32 ref) private {
        ledger.postWithBurn(address(this), amount, _settlement(-amount.toInt256().toInt128()), ref);
    }

    function _settlement(int128 amount) private pure returns (GeneralLedger.Line[] memory lines) {
        lines = new GeneralLedger.Line[](1);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Settlement, amount);
    }

    /// @dev The creditor account is the customer's address; anything wider names no account here.
    function _addressOf(bytes32 account) private pure returns (address) {
        return uint256(account) >> 160 == 0 ? address(uint160(uint256(account))) : address(0);
    }

    function _checkSignature(bytes32 digest, bytes calldata signature) private view {
        if (!partners.verify(CLEARING, digest, signature)) revert InvalidPartnerSignature();
    }
}
