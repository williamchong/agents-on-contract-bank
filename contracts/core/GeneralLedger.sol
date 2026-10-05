// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DepositToken} from "./DepositToken.sol";

/// @dev The bank's double-entry general ledger over the chart of accounts in docs/architecture.md,
/// and the only contract that creates or destroys deposit tokens. Amounts are signed, in cents:
/// a debit is positive and a credit negative, so every entry and the whole book sum to zero. The
/// chain keeps a running balance per account and emits each entry as an event; the entries are not
/// stored. The Deposits balance is not stored either; it is the token's supply, so the two cannot
/// disagree. See open question 8 in docs/plan.md.
contract GeneralLedger is AccessManaged {
    using SafeCast for uint256;
    using SafeCast for int256;

    enum Account {
        Settlement,
        Cash,
        Securities,
        Loans,
        Allowance,
        ReserveSurplus,
        DueFromReserve,
        Deposits,
        Equity
    }

    struct Line {
        Account account;
        int128 amount;
    }

    DepositToken public immutable token;
    uint256 public entryCount;
    mapping(Account => int256) private _balances;

    /// @dev `ref` is the operation's own reference, so its token movements and its entry can be
    /// joined; `poster` is the module that posted it.
    event EntryPosted(uint256 indexed id, bytes32 indexed ref, address indexed poster, Line[] lines);

    error UnbalancedEntry(int256 sum);
    error DepositsMoveOnlyWithTokens();
    error OpeningNotFirst();
    error HoldersMismatch(uint256 holders, uint256 amounts);

    constructor(address manager, DepositToken token_) AccessManaged(manager) {
        token = token_;
    }

    function balanceOf(Account account) public view returns (int256) {
        return account == Account.Deposits ? -token.totalSupply().toInt256() : _balances[account];
    }

    /// @dev Every account's balance, indexed by `Account`.
    function balances() external view returns (int256[] memory all) {
        all = new int256[](uint8(type(Account).max) + 1);
        for (uint8 i = 0; i < all.length; ++i) all[i] = balanceOf(Account(i));
    }

    /// @dev The opening balance sheet, as the first entry: the deposits each holder starts with,
    /// against the other side of the sheet in `lines`.
    function postOpening(
        address[] calldata holders,
        uint256[] calldata amounts,
        Line[] calldata lines,
        bytes32 ref
    ) external restricted returns (uint256) {
        if (entryCount != 0) revert OpeningNotFirst();
        if (holders.length != amounts.length) revert HoldersMismatch(holders.length, amounts.length);
        uint256 total;
        for (uint256 i = 0; i < holders.length; ++i) {
            token.mint(holders[i], amounts[i]);
            total += amounts[i];
        }
        return _post(lines, -total.toInt256().toInt128(), ref);
    }

    /// @dev An entry that moves no tokens, such as raising the loss allowance.
    function post(Line[] calldata lines, bytes32 ref) external restricted returns (uint256) {
        return _post(lines, 0, ref);
    }

    /// @dev Creates deposit tokens for `to` against the other side of the entry in `lines`.
    function postWithMint(
        address to,
        uint256 amount,
        Line[] calldata lines,
        bytes32 ref
    ) external restricted returns (uint256) {
        token.mint(to, amount);
        return _post(lines, -amount.toInt256().toInt128(), ref);
    }

    /// @dev Destroys deposit tokens held by `from`, usually a bank-owned account such as pending
    /// withdrawals, against the other side of the entry in `lines`.
    function postWithBurn(
        address from,
        uint256 amount,
        Line[] calldata lines,
        bytes32 ref
    ) external restricted returns (uint256) {
        token.burn(from, amount);
        return _post(lines, amount.toInt256().toInt128(), ref);
    }

    function _post(Line[] calldata lines, int128 deposits, bytes32 ref) private returns (uint256 id) {
        Line[] memory entry = new Line[](lines.length + (deposits == 0 ? 0 : 1));
        int256 sum = deposits;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].account == Account.Deposits) revert DepositsMoveOnlyWithTokens();
            _balances[lines[i].account] += lines[i].amount;
            sum += lines[i].amount;
            entry[i] = lines[i];
        }
        if (sum != 0) revert UnbalancedEntry(sum);
        if (deposits != 0) entry[lines.length] = Line(Account.Deposits, deposits);

        id = ++entryCount;
        emit EntryPosted(id, ref, msg.sender, entry);
    }
}
