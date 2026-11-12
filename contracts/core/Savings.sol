// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20uRWA} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20uRWA.sol";
import {DailyLimit} from "./DailyLimit.sol";
import {DepositToken} from "./DepositToken.sol";
import {GeneralLedger} from "./GeneralLedger.sol";
import {Rates} from "./Rates.sol";

/// @dev The savings account, a vault of deposit tokens whose shares carry the same freezes and forced
/// transfers as the deposit token, so a hold reaches money moved into savings. Shares are not a means of
/// payment: they move only by paying in, withdrawing or a forced transfer. Who may hold them is the
/// deposit token's allow-list, so a customer is admitted once. Closing the business day pays its
/// interest: the scheduler triggers the vault, which pays each day since the one it last paid at the
/// savings rate in force when it pays, creating deposit tokens into the vault against equity, so every share is worth
/// more. A business day ends at midnight Hong Kong time, as the daily limits do. Shares follow the deposit
/// token's pause, so one pause stops both, and no interest is paid while it lasts; the days it held up are
/// paid once the bank resumes. See open questions 6, 29 and 31 in docs/plan.md.
contract Savings is ERC4626, ERC20uRWA, AccessManaged {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 private constant BPS = 10_000;
    uint256 private constant DAYS_A_YEAR = 365;

    GeneralLedger public immutable ledger;
    Rates public immutable rates;
    /// @dev The last business day whose interest has been paid.
    uint64 public lastPaidDay;

    event InterestPaid(uint64 indexed day, bytes32 indexed ref, uint256 amount, uint256 rateBps);

    error SharesNotTransferable();

    constructor(
        address manager,
        DepositToken token,
        GeneralLedger ledger_,
        Rates rates_
    ) ERC20("Savings HKD", "sHKD") ERC4626(token) AccessManaged(manager) {
        ledger = ledger_;
        rates = rates_;
        // The day the vault opens is the first it pays; only a chain at its first day, as a test's is, starts
        // on the next.
        uint64 today = DailyLimit.today();
        lastPaidDay = today == 0 ? 0 : today - 1;
    }

    /// @dev Pays the interest of every business day up to today not yet paid, oldest first, each on the
    /// vault's holdings at the time, so it compounds. Does nothing once today is paid, so the scheduler
    /// may trigger it freely. The scheduler closes each day as it ends, so the days missed are few; a
    /// catch-up of years would not fit in a block, which the demo's jumps never ask for.
    function payInterestDue() external restricted {
        _requireTokenNotPaused();
        uint64 today = DailyLimit.today();
        uint64 day = lastPaidDay;
        if (day >= today) return;
        (uint256 rateBps, ) = rates.products();
        uint256 assets = totalAssets();
        while (day < today) {
            ++day;
            uint256 interest = (assets * rateBps) / (BPS * DAYS_A_YEAR);
            assets += interest;
            bytes32 ref = interestRef(day);
            if (interest > 0) {
                GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](1);
                lines[0] = GeneralLedger.Line(GeneralLedger.Account.Equity, interest.toInt256().toInt128());
                ledger.postWithMint(address(this), interest, lines, ref);
            }
            emit InterestPaid(day, ref, interest, rateBps);
        }
        lastPaidDay = day;
    }

    /// @dev The reference a day's interest entry carries.
    function interestRef(uint64 day) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), day));
    }

    function canTransact(address account) public view override returns (bool) {
        return DepositToken(asset()).canTransact(account);
    }

    /// @dev The vault is on the deposit token's allow-list to hold the savings, but shares paid to the
    /// vault itself could never be withdrawn.
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

    /// @dev ERC-4626 requires the limits to reflect what would succeed, so a frozen or blocked holder is
    /// told what they can actually take out. A freeze on the payer's deposit tokens is not shown in
    /// maxDeposit, which names only the receiver; it shows as a refusal.
    function maxRedeem(address owner) public view override returns (uint256) {
        return canSend(owner) ? available(owner) : 0;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return previewRedeem(maxRedeem(owner));
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

    function _requireTokenNotPaused() private view {
        if (DepositToken(asset()).paused()) revert Pausable.EnforcedPause();
    }

    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20uRWA) {
        _requireTokenNotPaused();
        if (from != address(0) && to != address(0) && !_isForcedTransfer()) revert SharesNotTransferable();
        super._update(from, to, amount);
    }
}
