// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {GeneralLedger} from "./GeneralLedger.sol";
import {PartnerKeys, Partners} from "./PartnerKeys.sol";

/// @dev Sales of the bank's liquid securities, booked as they settle. Treasury instructs a sale, finance
/// approves it, and the custodian settles it delivery against payment: the bills leave the bank's holding
/// and the cash reaches its settlement account together. The books follow the custodian's signed
/// settlement confirmation (sese.025), not the dealer's word: it posts securities down and the settlement
/// account up in one entry, once, and only for a sale approved and for its amount. The bills are sold at
/// the value the books hold them at, so no gain or loss is booked. Anyone may relay the confirmation, as its
/// authority is the signature alone. See open question 27 in docs/plan.md.
contract SecuritiesSales is EIP712, AccessManaged {
    using SafeCast for uint256;
    using SafeCast for int256;

    enum Status {
        None,
        Instructed,
        Approved,
        Settled
    }

    struct Sale {
        uint256 amount;
        Status status;
    }

    /// @dev sese.025: the custodian has delivered the bills and the cash has reached the settlement account.
    struct SettlementConfirmation {
        bytes32 tradeRef;
        uint256 amount;
        uint256 settledAt;
        bytes32 documentHash;
    }

    bytes32 private constant SETTLEMENT_CONFIRMATION_TYPEHASH =
        keccak256("SettlementConfirmation(bytes32 tradeRef,uint256 amount,uint256 settledAt,bytes32 documentHash)");

    GeneralLedger public immutable ledger;
    PartnerKeys public immutable partners;

    uint256 public saleCount;
    mapping(bytes32 ref => Sale) private _sales;

    event SaleInstructed(bytes32 indexed ref, uint256 amount);
    event SaleApproved(bytes32 indexed ref);
    event SaleSettled(bytes32 indexed ref, uint256 amount, uint256 settledAt, bytes32 documentHash);

    error ZeroAmount();
    error NotAwaiting(bytes32 ref, Status status);
    error UnknownSale(bytes32 ref, uint256 amount);
    error InvalidPartnerSignature();

    constructor(address manager, GeneralLedger ledger_, PartnerKeys partners_) EIP712("SecuritiesSales", "1") AccessManaged(manager) {
        ledger = ledger_;
        partners = partners_;
    }

    function sale(bytes32 ref) external view returns (Sale memory) {
        return _sales[ref];
    }

    /// @dev Treasury instructs a sale of `amount` of the holding. The custodian refuses one beyond the
    /// holding, and the ledger would too, as securities cannot go negative; such a sale is never settled
    /// and stays as it is, moving nothing.
    function instruct(uint256 amount) external restricted returns (bytes32 ref) {
        if (amount == 0) revert ZeroAmount();
        ref = keccak256(abi.encode(block.chainid, address(this), ++saleCount));
        _sales[ref] = Sale(amount, Status.Instructed);
        emit SaleInstructed(ref, amount);
    }

    /// @dev Finance approves the trade, which then goes to the custodian to settle.
    function approve(bytes32 ref) external restricted {
        Sale storage s = _sales[ref];
        if (s.status != Status.Instructed) revert NotAwaiting(ref, s.status);
        s.status = Status.Approved;
        emit SaleApproved(ref);
    }

    /// @dev Books an approved sale on the custodian's settlement confirmation.
    function settle(SettlementConfirmation calldata m, bytes calldata signature) external {
        if (!partners.verify(Partners.CUSTODIAN, hashSettlementConfirmation(m), signature)) revert InvalidPartnerSignature();
        Sale storage s = _sales[m.tradeRef];
        if (s.status != Status.Approved || s.amount != m.amount) revert UnknownSale(m.tradeRef, m.amount);
        s.status = Status.Settled;
        int128 line = m.amount.toInt256().toInt128();
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](2);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Securities, -line);
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Settlement, line);
        ledger.post(lines, m.tradeRef);
        emit SaleSettled(m.tradeRef, m.amount, m.settledAt, m.documentHash);
    }

    function hashSettlementConfirmation(SettlementConfirmation memory m) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(SETTLEMENT_CONFIRMATION_TYPEHASH, m.tradeRef, m.amount, m.settledAt, m.documentHash)));
    }
}
