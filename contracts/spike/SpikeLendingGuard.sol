// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SpikeLedger} from "./SpikeLedger.sol";

/// @dev Toolchain spike: the lending guard. A drawdown creates deposit tokens against a loan and
/// books the performing loan's allowance against equity, then both ratios must still hold or the
/// whole call is undone. Ratios are compared by cross-multiplying, so rounding never decides a
/// refusal, and a ratio exactly at its minimum passes. See open question 9 in docs/plan.md.
contract SpikeLendingGuard is AccessManaged {
    using SafeCast for uint256;
    using SafeCast for int256;

    uint256 private constant BPS = 10_000;

    SpikeLedger public immutable ledger;
    uint256 public capitalMinimumBps;
    uint256 public liquidityMinimumBps;
    uint256 public allowanceBps;

    /// @dev Capital is checked first, so a drawdown that breaches both is refused naming capital.
    error CapitalRatioBelowMinimum(uint256 ratioBps, uint256 minimumBps);
    error LiquidityRatioBelowMinimum(uint256 ratioBps, uint256 minimumBps);
    error RateAboveWhole(uint256 bps);

    constructor(
        address manager,
        SpikeLedger ledger_,
        uint256 capitalMinimumBps_,
        uint256 liquidityMinimumBps_,
        uint256 allowanceBps_
    ) AccessManaged(manager) {
        ledger = ledger_;
        _setMinimums(capitalMinimumBps_, liquidityMinimumBps_);
        _setAllowanceRate(allowanceBps_);
    }

    function setMinimums(uint256 capitalBps, uint256 liquidityBps) external restricted {
        _setMinimums(capitalBps, liquidityBps);
    }

    function setAllowanceRate(uint256 bps) external restricted {
        _setAllowanceRate(bps);
    }

    function drawdown(address borrower, uint256 amount, bytes32 ref) external restricted {
        ledger.postWithMint(borrower, amount, _lines(SpikeLedger.Account.Loans, amount.toInt256().toInt128()), ref);

        int128 allowance = Math.mulDiv(amount, allowanceBps, BPS, Math.Rounding.Ceil).toInt256().toInt128();
        if (allowance > 0) {
            SpikeLedger.Line[] memory lines = new SpikeLedger.Line[](2);
            lines[0] = SpikeLedger.Line(SpikeLedger.Account.Equity, allowance);
            lines[1] = SpikeLedger.Line(SpikeLedger.Account.Allowance, -allowance);
            ledger.post(lines, ref);
        }

        (int256 equity, int256 netLoans) = _capital();
        if (!_holds(equity, netLoans, capitalMinimumBps)) {
            revert CapitalRatioBelowMinimum(_ratio(equity, netLoans), capitalMinimumBps);
        }
        (int256 liquid, int256 deposits) = _liquidity();
        if (!_holds(liquid, deposits, liquidityMinimumBps)) {
            revert LiquidityRatioBelowMinimum(_ratio(liquid, deposits), liquidityMinimumBps);
        }
    }

    /// @dev Equity over loans net of the allowance, in basis points, rounded down. With no loans
    /// there is nothing to hold capital against, so the ratio is unbounded.
    function capitalRatioBps() public view returns (uint256) {
        (int256 equity, int256 netLoans) = _capital();
        return _ratio(equity, netLoans);
    }

    /// @dev Settlement, cash and liquid securities over deposits, in basis points, rounded down.
    function liquidityRatioBps() public view returns (uint256) {
        (int256 liquid, int256 deposits) = _liquidity();
        return _ratio(liquid, deposits);
    }

    /// @dev Equity and deposits are credit balances, so their sign is turned; the allowance is a
    /// negative asset and already lowers the loans it is added to.
    function _capital() private view returns (int256 equity, int256 netLoans) {
        equity = -ledger.balanceOf(SpikeLedger.Account.Equity);
        netLoans = ledger.balanceOf(SpikeLedger.Account.Loans) + ledger.balanceOf(SpikeLedger.Account.Allowance);
    }

    function _liquidity() private view returns (int256 liquid, int256 deposits) {
        liquid =
            ledger.balanceOf(SpikeLedger.Account.Settlement) +
            ledger.balanceOf(SpikeLedger.Account.Cash) +
            ledger.balanceOf(SpikeLedger.Account.Securities);
        deposits = -ledger.balanceOf(SpikeLedger.Account.Deposits);
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
    }

    function _setAllowanceRate(uint256 bps) private {
        if (bps > BPS) revert RateAboveWhole(bps);
        allowanceBps = bps;
    }

    function _lines(SpikeLedger.Account account, int128 amount) private pure returns (SpikeLedger.Line[] memory lines) {
        lines = new SpikeLedger.Line[](1);
        lines[0] = SpikeLedger.Line(account, amount);
    }
}
