// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BranchApprovals} from "./BranchApprovals.sol";
import {DepositToken} from "./DepositToken.sol";

/// @dev The assisted operations module: transfers a teller makes for a customer at the counter, on the
/// customer's device or card or on a signed paper slip. Each climbs the branch approval ladder, holding
/// the customer's money meanwhile, and reaches its recipient once approved. It holds the enforcer role,
/// which it uses only to take a paper instruction's amount, never beyond the customer's unfrozen
/// balance. See open question 19 in docs/plan.md and the paper instruction flow in
/// docs/architecture.md.
contract AssistedOperations is BranchApprovals {
    /// @dev The purpose a customer's authorisation of a transfer through a teller is given for.
    bytes32 public constant TRANSFER = "transfer";

    error NotAdmitted(address account);

    constructor(address manager, DepositToken token_, Ladder memory ladder_) BranchApprovals(manager, token_, ladder_) {}

    /// @dev A teller of `branch` transfers money for a customer to `to` on the customer's device or
    /// card, whose authorisation names this transfer's intent.
    function transfer(uint64 branch, address to, CardAuthorisation calldata authorisation) external returns (bytes32) {
        _checkRecipient(to);
        return _openSigned(branch, TRANSFER, to, authorisation);
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
        return _openOnPaper(branch, customer, to, amount, slipHash);
    }

    function _carryOut(bytes32, Operation storage op) internal override {
        token.transfer(op.recipient, op.amount);
    }

    function _checkRecipient(address to) private view {
        if (!token.canTransact(to)) revert NotAdmitted(to);
    }
}
