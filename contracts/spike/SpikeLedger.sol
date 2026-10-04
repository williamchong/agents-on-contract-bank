// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SpikeDepositToken} from "./SpikeDepositToken.sol";

/// @dev Ledger spike: a double-entry general ledger over the chart of accounts in
/// docs/architecture.md, which alone creates and destroys deposit tokens. Amounts are signed:
/// a debit is positive and a credit negative, so every entry and the whole book sum to zero.
/// The Deposits balance is not stored; it is the token's supply, so the two cannot disagree.
/// Three ways of keeping entries are compared below. See open question 8 in docs/plan.md.
abstract contract SpikeLedger is AccessManaged {
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

    /// @dev Packed into one storage slot, so design B is not charged for a wider amount than it needs.
    struct Line {
        Account account;
        int128 amount;
    }

    SpikeDepositToken public immutable token;
    uint256 public entryCount;
    mapping(Account => int256) private _balances;

    event EntryPosted(uint256 indexed id, bytes32 indexed ref, Line[] lines);

    error UnbalancedEntry(int256 sum);
    error DepositsMoveOnlyWithTokens();

    constructor(address manager, SpikeDepositToken token_) AccessManaged(manager) {
        token = token_;
    }

    function balanceOf(Account account) public view returns (int256) {
        return account == Account.Deposits ? -token.totalSupply().toInt256() : _balances[account];
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

    /// @dev Destroys deposit tokens held by `from`, in the full design a bank-owned account such as
    /// pending withdrawals, against the other side of the entry in `lines`.
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
        int256 sum = deposits;
        for (uint256 i = 0; i < lines.length; ++i) {
            if (lines[i].account == Account.Deposits) revert DepositsMoveOnlyWithTokens();
            _balances[lines[i].account] += lines[i].amount;
            sum += lines[i].amount;
        }
        if (sum != 0) revert UnbalancedEntry(sum);

        Line[] memory entry = new Line[](lines.length + (deposits == 0 ? 0 : 1));
        for (uint256 i = 0; i < lines.length; ++i) entry[i] = lines[i];
        if (deposits != 0) entry[lines.length] = Line(Account.Deposits, deposits);

        id = ++entryCount;
        _record(id, entry);
        emit EntryPosted(id, ref, entry);
    }

    function _record(uint256 id, Line[] memory entry) internal virtual;
}

/// @dev Design A: running balances on chain, entries in events only.
contract SpikeLedgerEvents is SpikeLedger {
    constructor(address manager, SpikeDepositToken token_) SpikeLedger(manager, token_) {}

    function _record(uint256, Line[] memory) internal override {}
}

/// @dev Design B: running balances, plus every line of every entry in storage.
contract SpikeLedgerStored is SpikeLedger {
    mapping(uint256 => Line[]) private _entries;

    constructor(address manager, SpikeDepositToken token_) SpikeLedger(manager, token_) {}

    function entry(uint256 id) external view returns (Line[] memory) {
        return _entries[id];
    }

    function _record(uint256 id, Line[] memory lines) internal override {
        for (uint256 i = 0; i < lines.length; ++i) _entries[id].push(lines[i]);
    }
}

/// @dev Design C: running balances, plus a hash of each entry so a later call can prove it is
/// given the entry as posted.
contract SpikeLedgerHashed is SpikeLedger {
    mapping(uint256 => bytes32) public entryHash;

    error EntryMismatch(uint256 id);

    constructor(address manager, SpikeDepositToken token_) SpikeLedger(manager, token_) {}

    function checkEntry(uint256 id, Line[] calldata entry) external view {
        if (keccak256(abi.encode(entry)) != entryHash[id]) revert EntryMismatch(id);
    }

    function _record(uint256 id, Line[] memory entry) internal override {
        entryHash[id] = keccak256(abi.encode(entry));
    }
}
