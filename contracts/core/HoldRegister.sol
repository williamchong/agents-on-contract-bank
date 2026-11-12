// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC20Restricted} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DepositToken} from "./DepositToken.sol";
import {Roles} from "./Roles.sol";
import {Savings} from "./Savings.sol";

/// @dev The register of named holds, holding the freezer role: an account's frozen amount is the
/// sum of its open holds. Support, compliance or a supervisor places a hold; a compliance hold is
/// lifted only by compliance, and any other by a supervisor or compliance. The dispute reversal module
/// places and lifts holds of its own, which only it lifts, when compliance approves or rejects the
/// dispute, so a dispute can never lose its hold while it is still open. A hold freezes the current
/// account first and the savings shares for what it does not cover. Who may call is decided here, not
/// by the access manager, because who lifts depends on who placed. See the access manager roles in
/// docs/roles.md and open question 29 in docs/plan.md.
contract HoldRegister {
    using EnumerableSet for EnumerableSet.UintSet;

    struct Hold {
        address account;
        uint256 amount;
        address placer;
        /// @dev The role the placer acted as, which decides who may lift the hold.
        uint64 role;
    }

    AccessManager public immutable manager;
    DepositToken public immutable token;
    Savings public immutable savings;

    uint256 public holdCount;
    mapping(uint256 id => Hold) private _holds;
    mapping(address account => EnumerableSet.UintSet) private _open;
    mapping(address account => uint256) public heldOf;

    event Placed(
        uint256 indexed id,
        address indexed account,
        uint64 role,
        uint256 amount,
        address placer,
        string reason
    );
    event Lifted(uint256 indexed id, address indexed account, address by);

    error NotPlacer(address caller, uint64 role);
    error NotLifter(address caller, uint64 role, uint256 id);
    error NoSuchHold(uint256 id);
    error ZeroAmount();

    constructor(AccessManager manager_, DepositToken token_, Savings savings_) {
        manager = manager_;
        token = token_;
        savings = savings_;
    }

    function hold(uint256 id) external view returns (Hold memory) {
        return _holds[id];
    }

    function holdsOf(address account) external view returns (uint256[] memory) {
        return _open[account].values();
    }

    /// @dev Places a hold of `amount` as the holder of `asRole`. A hold may exceed the balance, so
    /// it also freezes money still to arrive. The account must be admitted; a blocked one still is.
    function place(
        address account,
        uint256 amount,
        uint64 asRole,
        string calldata reason
    ) external returns (uint256 id) {
        bool fits = asRole == Roles.SUPPORT || asRole == Roles.COMPLIANCE || asRole == Roles.DISPUTE_HOLDER || _isSupervisor(asRole);
        if (!fits || !_has(asRole, msg.sender)) revert NotPlacer(msg.sender, asRole);
        if (amount == 0) revert ZeroAmount();
        if (token.getRestriction(account) == ERC20Restricted.Restriction.DEFAULT) {
            revert DepositToken.NotAdmitted(account);
        }

        id = ++holdCount;
        _holds[id] = Hold(account, amount, msg.sender, asRole);
        _open[account].add(id);
        heldOf[account] += amount;
        _apply(account);
        emit Placed(id, account, asRole, amount, msg.sender, reason);
    }

    /// @dev Lifts a hold as the holder of `asRole`: the dispute reversal module its own and only it,
    /// compliance any other, and a supervisor any other but compliance's.
    function lift(uint256 id, uint64 asRole) external {
        Hold memory h = _holds[id];
        if (h.placer == address(0)) revert NoSuchHold(id);
        if (!_mayLift(h.role, asRole) || !_has(asRole, msg.sender)) revert NotLifter(msg.sender, asRole, id);

        delete _holds[id];
        _open[h.account].remove(id);
        heldOf[h.account] -= h.amount;
        _apply(h.account);
        emit Lifted(id, h.account, msg.sender);
    }

    /// @dev Freezes the account's held total: the shares that withdrawing what its deposit tokens do not
    /// cover would take, as many as it has, and on the deposit token the rest of the hold, which may
    /// exceed the balance so money still to arrive is held too. As interest raises the frozen shares'
    /// value, their cover only grows.
    function _apply(address account) private {
        uint256 held = heldOf[account];
        uint256 balance = token.balanceOf(account);
        uint256 shares;
        if (held > balance) shares = Math.min(savings.balanceOf(account), savings.previewWithdraw(held - balance));
        uint256 covered = shares == 0 ? 0 : Math.min(savings.previewRedeem(shares), held);
        if (shares != savings.getFrozenTokens(account)) savings.setFrozenTokens(account, shares);
        if (held - covered != token.getFrozenTokens(account)) token.setFrozenTokens(account, held - covered);
    }

    function _mayLift(uint64 placedAs, uint64 asRole) private pure returns (bool) {
        if (placedAs == Roles.DISPUTE_HOLDER) return asRole == Roles.DISPUTE_HOLDER;
        if (asRole == Roles.COMPLIANCE) return true;
        return placedAs != Roles.COMPLIANCE && _isSupervisor(asRole);
    }

    /// @dev A supervisor of any branch, until accounts record their home branch.
    function _isSupervisor(uint64 role) private pure returns (bool) {
        return Roles.branchRole(role) == Roles.SUPERVISOR;
    }

    function _has(uint64 role, address account) private view returns (bool member) {
        (member, ) = manager.hasRole(role, account);
    }
}
