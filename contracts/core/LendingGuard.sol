// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Attestations} from "./Attestations.sol";
import {GeneralLedger} from "./GeneralLedger.sol";
import {Rates} from "./Rates.sol";

/// @dev The lending guard, the only path that posts a loan drawdown. It holds the bookkeeper role and
/// posts the loan, the deposit tokens it creates for the borrower and the performing loan's allowance
/// charged to equity as one entry, then refuses the whole drawdown unless the settlement and
/// securities figures are current and both ratios still hold. It posts every other entry for a loan
/// too, on the loans module's word, and names each in an event the income statement is read from: an
/// instalment collected, the allowance measured again and a write-off. Capital is checked first, so a drawdown
/// that breaches both is refused naming capital, with the ratio it would have left. Ratios are compared
/// by cross-multiplying, so rounding never decides a refusal, and a ratio exactly at its minimum
/// passes. The ledger stays a book of record; checking the ratios on every drawdown is the one
/// departure from a real bank. See open questions 9, 25 and 28 in docs/plan.md.
contract LendingGuard is AccessManaged {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 private constant BPS = 10_000;

    GeneralLedger public immutable ledger;
    Attestations public immutable attestations;
    Rates public immutable rates;
    uint256 public capitalMinimumBps;
    uint256 public liquidityMinimumBps;

    /// @dev A drawdown posted within both ratios, with what they stand at after it.
    event DrawnWithinRatios(bytes32 indexed ref, address indexed borrower, uint256 amount, uint256 allowance, uint256 capitalBps, uint256 liquidityBps);
    /// @dev An instalment taken from the borrower: the principal off loans, the interest income.
    event InstalmentPosted(bytes32 indexed ref, uint256 principal, uint256 interest);
    /// @dev The allowance raised, charged to equity, or released to it.
    event AllowanceMoved(bytes32 indexed ref, int256 change);
    /// @dev A loan removed against its allowance, the shortfall charged to equity.
    event WriteOffPosted(bytes32 indexed ref, uint256 principal, uint256 allowance, uint256 shortfall);
    event MinimumsSet(uint256 capitalBps, uint256 liquidityBps);

    error CapitalRatioBelowMinimum(uint256 ratioBps, uint256 minimumBps);
    error LiquidityRatioBelowMinimum(uint256 ratioBps, uint256 minimumBps);
    error FigureNotCurrent(GeneralLedger.Account account);
    error RateAboveWhole(uint256 bps);

    constructor(
        address manager,
        GeneralLedger ledger_,
        Attestations attestations_,
        Rates rates_,
        uint256 capitalMinimumBps_,
        uint256 liquidityMinimumBps_
    ) AccessManaged(manager) {
        ledger = ledger_;
        attestations = attestations_;
        rates = rates_;
        _setMinimums(capitalMinimumBps_, liquidityMinimumBps_);
    }

    function setMinimums(uint256 capitalBps, uint256 liquidityBps) external restricted {
        _setMinimums(capitalBps, liquidityBps);
    }

    /// @dev Draws `amount` down to `borrower` under the loan's reference `ref`, and returns the
    /// performing allowance posted with it.
    function drawdown(address borrower, uint256 amount, bytes32 ref) external restricted returns (uint256 allowance) {
        _requireCurrent(GeneralLedger.Account.Settlement);
        _requireCurrent(GeneralLedger.Account.Securities);

        (uint256 performingBps, , ) = rates.allowance();
        allowance = Math.mulDiv(amount, performingBps, BPS, Math.Rounding.Ceil);
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](allowance > 0 ? 3 : 1);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Loans, _line(amount));
        if (allowance > 0) {
            int128 a = _line(allowance);
            lines[1] = GeneralLedger.Line(GeneralLedger.Account.Equity, a);
            lines[2] = GeneralLedger.Line(GeneralLedger.Account.Allowance, -a);
        }
        ledger.postWithMint(borrower, amount, lines, ref);

        (int256 equity, int256 netLoans) = _capital();
        uint256 capital = _ratio(equity, netLoans);
        if (!_holds(equity, netLoans, capitalMinimumBps)) revert CapitalRatioBelowMinimum(capital, capitalMinimumBps);
        (int256 liquid, int256 deposits) = _liquidity();
        uint256 liquidity = _ratio(liquid, deposits);
        if (!_holds(liquid, deposits, liquidityMinimumBps)) revert LiquidityRatioBelowMinimum(liquidity, liquidityMinimumBps);
        emit DrawnWithinRatios(ref, borrower, amount, allowance, capital, liquidity);
    }

    /// @dev Destroys an instalment the caller collected, against the principal it repays and the
    /// interest it earns.
    function collect(bytes32 ref, uint256 principal, uint256 interest) external restricted {
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](interest > 0 ? 2 : 1);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Loans, -_line(principal));
        if (interest > 0) lines[1] = GeneralLedger.Line(GeneralLedger.Account.Equity, -_line(interest));
        ledger.postWithBurn(msg.sender, principal + interest, lines, ref);
        emit InstalmentPosted(ref, principal, interest);
    }

    /// @dev Raises a loan's allowance by `change` against equity, or releases it when negative.
    function measure(bytes32 ref, int256 change) external restricted {
        int128 amount = change.toInt128();
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](2);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Equity, amount);
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Allowance, -amount);
        ledger.post(lines, ref);
        emit AllowanceMoved(ref, change);
    }

    /// @dev Removes `principal` outstanding against the loan's `allowance`, the rest charged to equity.
    function writeOff(bytes32 ref, uint256 principal, uint256 allowance) external restricted {
        uint256 shortfall = principal - allowance;
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](shortfall > 0 ? 3 : 2);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Loans, -_line(principal));
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Allowance, _line(allowance));
        if (shortfall > 0) lines[2] = GeneralLedger.Line(GeneralLedger.Account.Equity, _line(shortfall));
        ledger.post(lines, ref);
        emit WriteOffPosted(ref, principal, allowance, shortfall);
    }

    /// @dev Equity over loans net of the allowance, in basis points, rounded down. With no loans
    /// there is nothing to hold capital against, so the ratio is unbounded.
    function capitalRatioBps() external view returns (uint256) {
        (int256 equity, int256 netLoans) = _capital();
        return _ratio(equity, netLoans);
    }

    /// @dev Settlement, cash and liquid securities over deposits, in basis points, rounded down.
    function liquidityRatioBps() external view returns (uint256) {
        (int256 liquid, int256 deposits) = _liquidity();
        return _ratio(liquid, deposits);
    }

    function _line(uint256 amount) private pure returns (int128) {
        return amount.toInt256().toInt128();
    }

    function _requireCurrent(GeneralLedger.Account account) private view {
        if (!attestations.isCurrent(account)) revert FigureNotCurrent(account);
    }

    /// @dev Equity and deposits are credit balances, so their sign is turned; the allowance is a
    /// negative asset and already lowers the loans it is added to.
    function _capital() private view returns (int256 equity, int256 netLoans) {
        equity = -ledger.balanceOf(GeneralLedger.Account.Equity);
        netLoans = ledger.balanceOf(GeneralLedger.Account.Loans) + ledger.balanceOf(GeneralLedger.Account.Allowance);
    }

    /// @dev The reserve surplus and funds due from the reserve are not counted; they are not the bank's
    /// to spend until they reach the settlement account.
    function _liquidity() private view returns (int256 liquid, int256 deposits) {
        liquid =
            ledger.balanceOf(GeneralLedger.Account.Settlement) +
            ledger.balanceOf(GeneralLedger.Account.Cash) +
            ledger.balanceOf(GeneralLedger.Account.Securities);
        deposits = -ledger.balanceOf(GeneralLedger.Account.Deposits);
    }

    /// @dev Negative equity or liquid assets never hold, whatever they are set against; with
    /// nothing to set them against, anything else does. Agrees with `_ratio` rounded down.
    function _holds(int256 numerator, int256 denominator, uint256 minimumBps) private pure returns (bool) {
        if (numerator < 0) return false;
        if (denominator <= 0) return true;
        return uint256(numerator) * BPS >= minimumBps * uint256(denominator);
    }

    function _ratio(int256 numerator, int256 denominator) private pure returns (uint256) {
        if (numerator < 0) return 0;
        if (denominator <= 0) return type(uint256).max;
        return (uint256(numerator) * BPS) / uint256(denominator);
    }

    function _setMinimums(uint256 capitalBps, uint256 liquidityBps) private {
        if (capitalBps > BPS) revert RateAboveWhole(capitalBps);
        if (liquidityBps > BPS) revert RateAboveWhole(liquidityBps);
        capitalMinimumBps = capitalBps;
        liquidityMinimumBps = liquidityBps;
        emit MinimumsSet(capitalBps, liquidityBps);
    }
}
