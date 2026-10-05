// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20TransferAuthorization} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20TransferAuthorization.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC20uRWA} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20uRWA.sol";

/// @dev The deposit token: one token is one Hong Kong dollar the bank owes its holder, counted in
/// cents. Freezes, the allow-list, the block-list and forced transfers come from ERC-7943, and
/// customer-signed transfers from EIP-3009. Every privileged call is decided by the access
/// manager; only the general ledger may create or destroy tokens. See docs/standards.md.
contract DepositToken is ERC20, EIP712, ERC20TransferAuthorization, ERC20uRWA, AccessManaged {
    error NotAdmitted(address account);
    error NotBlocked(address account);

    constructor(address manager) ERC20("Deposit HKD", "dHKD") EIP712("Deposit HKD", "1") AccessManaged(manager) {}

    function decimals() public pure override returns (uint8) {
        return 2;
    }

    function mint(address to, uint256 amount) external restricted {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external restricted {
        _burn(from, amount);
    }

    /// @dev Admits an onboarded customer or a bank-owned account.
    function allowUser(address account) external restricted {
        _allowUser(account);
    }

    /// @dev A blocked account can neither send nor receive; only a forced transfer moves its money.
    /// Only an admitted account can be blocked, as no one else can transact anyway, so lifting a block
    /// is never a way to admit someone the bank has not onboarded.
    function blockUser(address account) external restricted {
        if (getRestriction(account) != Restriction.ALLOWED) revert NotAdmitted(account);
        _blockUser(account);
    }

    function unblockUser(address account) external restricted {
        if (getRestriction(account) != Restriction.BLOCKED) revert NotBlocked(account);
        _allowUser(account);
    }

    /// @dev Allow-list: only accounts the bank has admitted may hold or move the token.
    function canTransact(address account) public view override returns (bool) {
        return getRestriction(account) == Restriction.ALLOWED;
    }

    function setFrozenTokens(address account, uint256 amount) public override restricted returns (bool) {
        return super.setFrozenTokens(account, amount);
    }

    /// @dev A forced transfer from the zero address would create money outside the ledger.
    function forcedTransfer(address from, address to, uint256 amount) public override restricted returns (bool) {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        return super.forcedTransfer(from, to, amount);
    }

    /// @dev Both hooks are covered by `restricted` on the public functions above.
    function _checkEnforcer(address, address, uint256) internal view override {}

    function _checkFreezer(address, uint256) internal view override {}

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20uRWA) {
        super._update(from, to, amount);
    }
}
