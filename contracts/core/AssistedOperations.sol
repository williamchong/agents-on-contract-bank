// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccountRecovery} from "./AccountRecovery.sol";
import {BranchApprovals} from "./BranchApprovals.sol";
import {DepositToken} from "./DepositToken.sol";
import {Payments} from "./Payments.sol";

/// @dev The assisted operations module: transfers and payments out a teller makes for a customer at
/// the counter, on the customer's device or card or on a signed paper slip. Each climbs the branch
/// approval ladder, holding the customer's money meanwhile, and once approved a transfer reaches its
/// recipient and a payment is handed to the payments module in the customer's name. It holds the
/// enforcer role, which it uses only to take a paper instruction's amount, never beyond the customer's
/// unfrozen balance, and the payment originator role, which it uses only to name the customer whose
/// money it hands over as the payer. See open question 19 in docs/plan.md and the paper instruction
/// flow in docs/architecture.md.
contract AssistedOperations is BranchApprovals {
    /// @dev The purpose a customer's authorisation of a transfer through a teller is given for.
    bytes32 public constant TRANSFER = "transfer";
    /// @dev What a payment out's purpose is made from, with its payee's hash.
    bytes32 public constant PAYMENT = "payment";

    Payments public immutable payments;

    /// @dev An approved payment out handed to the payments module, under the payment's own reference.
    event PaymentHandedOver(bytes32 indexed ref, bytes32 indexed paymentRef);

    error NotAdmitted(address account);
    error NoPayee();

    constructor(
        address manager,
        DepositToken token_,
        AccountRecovery recovery_,
        Payments payments_,
        Ladder memory ladder_
    ) BranchApprovals(manager, token_, recovery_, ladder_) {
        payments = payments_;
    }

    /// @dev The purpose a customer's authorisation of a payment out to `payeeHash` through a teller is
    /// given for, so a teller cannot send it to another payee.
    function paymentPurpose(bytes32 payeeHash) public pure returns (bytes32) {
        return keccak256(abi.encode(PAYMENT, payeeHash));
    }

    /// @dev A teller of `branch` transfers money for a customer to `to` on the customer's device or
    /// card, whose authorisation names this transfer's intent.
    function transfer(uint64 branch, address to, CardAuthorisation calldata authorisation) external returns (bytes32) {
        _checkRecipient(to);
        return _openSigned(branch, TRANSFER, to, 0, authorisation);
    }

    /// @dev A teller of `branch` transfers money for a customer to `to` on the customer's signed paper
    /// slip, whose scan's hash is recorded with it.
    function transferOnPaper(
        uint64 branch,
        address customer,
        address to,
        uint256 amount,
        bytes32 slipHash
    ) external returns (bytes32) {
        _checkRecipient(to);
        return _openOnPaper(branch, customer, to, 0, amount, slipHash);
    }

    /// @dev A teller of `branch` pays someone at another bank for a customer on the customer's device or
    /// card, whose authorisation names the payee's hash in its intent.
    function pay(uint64 branch, bytes32 payeeHash, CardAuthorisation calldata authorisation) external returns (bytes32) {
        _checkPayee(payeeHash);
        return _openSigned(branch, paymentPurpose(payeeHash), address(payments), payeeHash, authorisation);
    }

    /// @dev A teller of `branch` pays someone at another bank for a customer on the customer's signed
    /// paper slip, which names the payee whose hash is recorded with it.
    function payOnPaper(
        uint64 branch,
        address customer,
        bytes32 payeeHash,
        uint256 amount,
        bytes32 slipHash
    ) external returns (bytes32) {
        _checkPayee(payeeHash);
        return _openOnPaper(branch, customer, address(payments), payeeHash, amount, slipHash);
    }

    function _carryOut(bytes32 ref, Operation storage op) internal override {
        if (op.payee == 0) {
            token.transfer(op.recipient, op.amount);
            return;
        }
        token.approve(address(payments), op.amount);
        emit PaymentHandedOver(ref, payments.payFor(op.customer, op.amount, op.payee));
    }

    /// @dev Money sent to the payments module or to this one would belong to no payment or operation.
    function _checkRecipient(address to) private view {
        if (to == address(payments) || to == address(this) || !token.canTransact(to)) revert NotAdmitted(to);
    }

    function _checkPayee(bytes32 payeeHash) private pure {
        if (payeeHash == 0) revert NoPayee();
    }
}
