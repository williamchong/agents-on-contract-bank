// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DailyLimit} from "./DailyLimit.sol";

/// @dev Each enrolled customer's daily limits on the app channel and their register of payees. The deposit
/// token counts every movement out of a customer's account that is not a forced transfer, unless it goes
/// into a module that keeps its own channel's limit. One to anyone the customer has not registered, another
/// customer of the bank by their address or someone at another bank through the payments module, also
/// counts against the unregistered payee limit, inside the app limit. Both reset at
/// midnight Hong Kong time. A payee registered from a device takes effect after the payee waiting period,
/// so one registered with a stolen phone cannot be paid at once. A customer may lower their own limits
/// from their device; raising them again needs the branch. See open question 20 in docs/plan.md.
contract CustomerLimits is AccessManaged {
    using DailyLimit for DailyLimit.Limiter;
    using SafeCast for uint256;

    struct Limits {
        uint256 app;
        uint256 unregistered;
        uint256 payeeWait;
    }

    /// @dev A customer's own lower limits, zero where they set none.
    struct OwnLimits {
        uint256 app;
        uint256 unregistered;
    }

    Limits public limits;
    mapping(address customer => bool) public enrolled;
    /// @dev How a movement into a bank module counts: not at all for one that keeps its own channel's
    /// limit, and against the app limit only for one that checks the payee itself.
    enum Channel {
        App,
        Own,
        PayeeCheckedThere
    }

    mapping(address module => Channel) public channelOf;
    mapping(address customer => OwnLimits) private _own;
    mapping(address customer => mapping(bytes32 payee => uint48 effectiveAt)) private _payees;
    DailyLimit.Limiter private _app;
    DailyLimit.Limiter private _unregistered;

    event Enrolled(address indexed customer);
    event ChannelSet(address indexed module, Channel channel);
    event LimitsSet(Limits limits);
    event OwnLimitsLowered(address indexed customer, uint256 app, uint256 unregistered);
    event PayeeRegistered(address indexed customer, bytes32 indexed payee, uint48 effectiveAt);
    event PayeeRemoved(address indexed customer, bytes32 indexed payee);

    error NotEnrolled(address account);
    error NotLower(uint256 requested, uint256 current);
    error ZeroLimit();

    constructor(address manager, Limits memory limits_) AccessManaged(manager) {
        limits = limits_;
    }

    // Views

    /// @dev The customer's app limit for a day: the bank's, or lower if they set one.
    function appLimit(address customer) public view returns (uint256) {
        return _lower(limits.app, _own[customer].app);
    }

    /// @dev The customer's unregistered payee limit for a day, never above their app limit.
    function unregisteredLimit(address customer) public view returns (uint256) {
        return _lower(_lower(limits.unregistered, _own[customer].unregistered), appLimit(customer));
    }

    function appAvailable(address customer) external view returns (uint256) {
        return _app.available(_key(customer), appLimit(customer));
    }

    function unregisteredAvailable(address customer) external view returns (uint256) {
        return _unregistered.available(_key(customer), unregisteredLimit(customer));
    }

    /// @dev Whether `payee` is on the customer's register and its waiting period has passed.
    function isPayee(address customer, bytes32 payee) public view returns (bool) {
        uint48 at = _payees[customer][payee];
        return at != 0 && block.timestamp >= at;
    }

    // Governance

    /// @dev Enrols an onboarded customer; until the onboarding module exists, governance does it.
    function enrol(address customer) external restricted {
        enrolled[customer] = true;
        emit Enrolled(customer);
    }

    function setChannel(address module, Channel channel) external restricted {
        channelOf[module] = channel;
        emit ChannelSet(module, channel);
    }

    function setLimits(Limits calldata limits_) external restricted {
        limits = limits_;
        emit LimitsSet(limits_);
    }

    // Counting, by the token and the payments module

    /// @dev Counts a movement out of `from` against their app limit, unless `from` is not an enrolled
    /// customer or `to` keeps its own channel's limit, and against the unregistered payee limit too
    /// when `to` is not on their register by address.
    function countMovement(address from, address to, uint256 amount) external restricted {
        if (!enrolled[from]) return;
        Channel channel = channelOf[to];
        if (channel == Channel.Own) return;
        _app.consume(_key(from), amount, appLimit(from));
        if (channel == Channel.App) _countUnregistered(from, payeeOf(to), amount);
    }

    /// @dev The payee hash an account of the bank is registered under: its address.
    function payeeOf(address account) public pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    /// @dev Counts a payment out to `payee` against the payer's unregistered payee limit, unless the
    /// payee is on their register.
    /// Returns whether it was counted there, so the payments module can give it back if the payment
    /// comes back.
    function countPayment(address payer, bytes32 payee, uint256 amount) external restricted returns (bool unregistered) {
        return enrolled[payer] && _countUnregistered(payer, payee, amount);
    }

    /// @dev Whether a movement from `from` into `module` is counted against the app limit, as the token's
    /// count does it, so a module can record what it took.
    function countsApp(address from, address module) external view returns (bool) {
        return enrolled[from] && channelOf[module] != Channel.Own;
    }

    /// @dev Gives back what a payment out counted on `day`, against the app limit and the unregistered
    /// payee limit as the flags say it was, when the payment comes back: stopped by compliance or rejected
    /// by the receiving bank, as a failed dispense gives back the ATM limit. A day already passed has
    /// nothing to give back.
    function releasePayment(address payer, uint256 amount, uint64 day, bool app, bool unregistered) external restricted {
        if (app) _app.release(_key(payer), amount, day);
        if (unregistered) _unregistered.release(_key(payer), amount, day);
    }

    // The customer, from their own device

    /// @dev Registers a payee, effective once the payee waiting period has passed. A payee already on the
    /// register keeps the time it took effect.
    function registerPayee(bytes32 payee) external returns (uint48 effectiveAt) {
        _requireEnrolled(msg.sender);
        effectiveAt = _payees[msg.sender][payee];
        if (effectiveAt != 0) return effectiveAt;
        effectiveAt = (block.timestamp + limits.payeeWait).toUint48();
        _payees[msg.sender][payee] = effectiveAt;
        emit PayeeRegistered(msg.sender, payee, effectiveAt);
    }

    function removePayee(bytes32 payee) external {
        delete _payees[msg.sender][payee];
        emit PayeeRemoved(msg.sender, payee);
    }

    /// @dev Lowers the customer's own limits at once. Neither may be raised here; that needs the branch.
    /// Zero is refused, as it would read as no limit set; a customer who wants nothing to leave asks
    /// support for a freeze.
    function lowerLimits(uint256 app, uint256 unregistered) external {
        _requireEnrolled(msg.sender);
        if (app == 0 || unregistered == 0) revert ZeroLimit();
        if (app > appLimit(msg.sender)) revert NotLower(app, appLimit(msg.sender));
        if (unregistered > unregisteredLimit(msg.sender)) revert NotLower(unregistered, unregisteredLimit(msg.sender));
        _own[msg.sender] = OwnLimits(app, unregistered);
        emit OwnLimitsLowered(msg.sender, app, unregistered);
    }

    // Internal

    function _countUnregistered(address customer, bytes32 payee, uint256 amount) private returns (bool counted) {
        if (isPayee(customer, payee)) return false;
        _unregistered.consume(_key(customer), amount, unregisteredLimit(customer));
        return true;
    }

    function _requireEnrolled(address account) private view {
        if (!enrolled[account]) revert NotEnrolled(account);
    }

    /// @dev The lower of the bank's limit and the customer's own, where they set one.
    function _lower(uint256 bank, uint256 own) private pure returns (uint256) {
        return own != 0 && own < bank ? own : bank;
    }

    function _key(address customer) private pure returns (bytes32) {
        return bytes32(uint256(uint160(customer)));
    }
}
