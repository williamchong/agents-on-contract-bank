// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20TransferAuthorization} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20TransferAuthorization.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC20uRWA} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20uRWA.sol";

/// @dev Toolchain spike: the deposit token's base, with freezes, an allow-list and forced transfers
/// from ERC-7943, customer-signed transfers from EIP-3009, and every privileged call decided by an
/// access manager. Minting here stands in for the general ledger, which is not written yet.
contract SpikeDepositToken is ERC20, EIP712, ERC20TransferAuthorization, ERC20uRWA, AccessManaged {
    constructor(address manager) ERC20("Spike Deposit", "SDEP") EIP712("Spike Deposit", "1") AccessManaged(manager) {}

    function mint(address to, uint256 amount) external restricted {
        _mint(to, amount);
    }

    function allowUser(address account) external restricted {
        _allowUser(account);
    }

    /// @dev Allow-list: only accounts the bank has admitted may hold or move the token.
    function canTransact(address account) public view override returns (bool) {
        return getRestriction(account) == Restriction.ALLOWED;
    }

    function setFrozenTokens(address account, uint256 amount) public override restricted returns (bool) {
        return super.setFrozenTokens(account, amount);
    }

    function forcedTransfer(address from, address to, uint256 amount) public override restricted returns (bool) {
        return super.forcedTransfer(from, to, amount);
    }

    /// @dev Both hooks are covered by `restricted` on the public functions above.
    function _checkEnforcer(address, address, uint256) internal view override {}

    function _checkFreezer(address, uint256) internal view override {}

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20uRWA) {
        super._update(from, to, amount);
    }
}
