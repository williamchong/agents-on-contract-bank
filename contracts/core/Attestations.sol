// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {GeneralLedger} from "./GeneralLedger.sol";
import {PartnerKeys, Partners} from "./PartnerKeys.sol";

/// @dev Attested figures: the partners' signed statements of the assets the bank holds off chain,
/// each compared with the ledger's balance at the statement's own date. The clearing system attests
/// the settlement account (camt.053) and the custodian liquid securities (semt.002); which account a
/// statement is for is decided by whose key signed it. A mismatch posts nothing, since the chain
/// cannot know which side is right: the figure is marked unmatched until a later statement matches.
/// A figure is current while it matched and is no older than the statement maximum age, which the
/// lending guard reads. Anyone may relay a statement: its authority is the signature alone. See
/// open question 16 in docs/plan.md.
contract Attestations is EIP712, AccessManaged {
    using SafeCast for uint256;

    /// @dev camt.053, or semt.002 for securities: the account's closing balance at `asOf`.
    struct Statement {
        bytes32 statementId;
        uint256 sequence;
        uint256 closingBalance;
        uint256 asOf;
        bytes32 documentHash;
    }

    struct Figure {
        uint256 amount;
        uint256 ledgerBalance;
        uint256 asOf;
        uint256 sequence;
        bool matched;
    }

    bytes32 private constant STATEMENT_TYPEHASH =
        keccak256("Statement(bytes32 statementId,uint256 sequence,uint256 closingBalance,uint256 asOf,bytes32 documentHash)");

    GeneralLedger public immutable ledger;
    PartnerKeys public immutable partners;

    uint256 public maxAge;
    mapping(GeneralLedger.Account => Figure) private _figures;

    event StatementAccepted(
        GeneralLedger.Account indexed account,
        bytes32 indexed statementId,
        uint256 sequence,
        uint256 closingBalance,
        uint256 ledgerBalance,
        bool matched,
        bytes32 documentHash
    );
    event MaxAgeSet(uint256 maxAge);

    error NotAttested(GeneralLedger.Account account);
    error InvalidPartnerSignature();
    error StaleStatement(uint256 sequence, uint256 latest);
    error FutureStatement(uint256 asOf);
    error OutOfDateStatement(uint256 asOf, uint256 latest);

    constructor(
        address manager,
        GeneralLedger ledger_,
        PartnerKeys partners_,
        uint256 maxAge_
    ) EIP712("Attestations", "1") AccessManaged(manager) {
        ledger = ledger_;
        partners = partners_;
        maxAge = maxAge_;
    }

    /// @dev The partner whose statements attest `account`, or zero if none does. Cash is attested
    /// by counts, which arrive with cash operations.
    function partnerFor(GeneralLedger.Account account) public pure returns (bytes32) {
        if (account == GeneralLedger.Account.Settlement) return Partners.CLEARING;
        if (account == GeneralLedger.Account.Securities) return Partners.CUSTODIAN;
        return 0;
    }

    function figure(GeneralLedger.Account account) external view returns (Figure memory) {
        return _figures[account];
    }

    /// @dev Whether the account's latest figure matched the ledger and is young enough to rely on.
    function isCurrent(GeneralLedger.Account account) external view returns (bool) {
        Figure storage f = _figures[account];
        return f.matched && block.timestamp - f.asOf <= maxAge;
    }

    function hashStatement(Statement calldata m) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(abi.encode(STATEMENT_TYPEHASH, m.statementId, m.sequence, m.closingBalance, m.asOf, m.documentHash))
            );
    }

    function setMaxAge(uint256 maxAge_) external restricted {
        maxAge = maxAge_;
        emit MaxAgeSet(maxAge_);
    }

    /// @dev Statements are accepted in order only, so an old one cannot be replayed over a newer
    /// figure; a number may be skipped, as a statement that never arrived is superseded by the next.
    /// A statement must be dated before this block, as later transactions in it may still move the
    /// balance it attests.
    function acceptStatement(
        GeneralLedger.Account account,
        Statement calldata m,
        bytes calldata signature
    ) external {
        bytes32 partner = partnerFor(account);
        if (partner == 0) revert NotAttested(account);
        Figure storage f = _figures[account];
        if (m.sequence <= f.sequence) revert StaleStatement(m.sequence, f.sequence);
        if (m.asOf >= block.timestamp) revert FutureStatement(m.asOf);
        if (m.asOf <= f.asOf) revert OutOfDateStatement(m.asOf, f.asOf);
        if (!partners.verify(partner, hashStatement(m), signature)) revert InvalidPartnerSignature();

        uint256 ledgerBalance = ledger.balanceAt(account, m.asOf.toUint48());
        bool matched = m.closingBalance == ledgerBalance;
        _figures[account] = Figure(m.closingBalance, ledgerBalance, m.asOf, m.sequence, matched);
        emit StatementAccepted(account, m.statementId, m.sequence, m.closingBalance, ledgerBalance, matched, m.documentHash);
    }
}
