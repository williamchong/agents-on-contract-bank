// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC20uRWA} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20uRWA.sol";
import {SpikeDepositToken} from "./SpikeDepositToken.sol";

/// @dev Toolchain spike: the savings account, a vault of deposit tokens whose shares carry the same
/// freezes and forced transfers as the deposit token, so a hold reaches money moved into savings.
/// Shares are not a means of payment: they move only by paying in, withdrawing or a forced
/// transfer. Who may hold them is the deposit token's allow-list, so a customer is admitted once.
/// See open question 6 in docs/plan.md.
contract SpikeSavings is ERC4626, ERC20uRWA, AccessManaged {
    error SharesNotTransferable();

    constructor(
        address manager,
        SpikeDepositToken deposits
    ) ERC20("Spike Savings", "SSAV") ERC4626(deposits) AccessManaged(manager) {}

    function canTransact(address account) public view override returns (bool) {
        return SpikeDepositToken(asset()).canTransact(account);
    }

    /// @dev The vault is on the deposit token's allow-list to hold the savings, but shares paid to
    /// the vault itself could never be withdrawn.
    function canReceive(address account) public view override returns (bool) {
        return account != address(this) && super.canReceive(account);
    }

    function setFrozenTokens(address account, uint256 amount) public override restricted returns (bool) {
        return super.setFrozenTokens(account, amount);
    }

    /// @dev A forced transfer from the zero address would create shares backed by nothing.
    function forcedTransfer(address from, address to, uint256 amount) public override restricted returns (bool) {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        return super.forcedTransfer(from, to, amount);
    }

    /// @dev ERC-4626 requires the limits to reflect what would succeed, so a frozen or blocked
    /// holder is told what they can actually take out. A freeze on the payer's deposit tokens is
    /// not shown in maxDeposit, which names only the receiver; it shows as a refusal.
    function maxRedeem(address owner) public view override returns (uint256) {
        return canSend(owner) ? available(owner) : 0;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return canReceive(receiver) ? super.maxDeposit(receiver) : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return canReceive(receiver) ? super.maxMint(receiver) : 0;
    }

    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return super.decimals();
    }

    /// @dev Virtual shares: a first saver's gift to the vault would have to be a million times a later
    /// saver's payment to round it down to nothing, so making a later saver lose money costs far more.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Both hooks are covered by `restricted` on the public functions above.
    function _checkEnforcer(address, address, uint256) internal view override {}

    function _checkFreezer(address, uint256) internal view override {}

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20uRWA) {
        if (from != address(0) && to != address(0) && !_isForcedTransfer()) revert SharesNotTransferable();
        super._update(from, to, amount);
    }
}
