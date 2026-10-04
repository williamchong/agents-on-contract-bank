// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";

/// @dev Time spike: the business day is worked out from block time, the one clock that time locks,
/// access manager delays, EIP-3009 validity windows and rate limits all read, so the bank's day
/// and theirs cannot drift apart. The scheduler moves time only on the local chain, and block time
/// cannot go back, so the day moves forward only. See open question 11 in docs/plan.md.
abstract contract SpikeClock {
    uint256 public immutable genesis;

    constructor(uint256 genesis_) {
        genesis = genesis_;
    }

    function businessDay() public view returns (uint256) {
        return (block.timestamp - genesis) / 1 days;
    }
}

/// @dev Scheduled work in the shape of the daily savings interest: the scheduler only says that due
/// work should run, and the contract works out from its own state how many days are due, so a jump
/// of several days runs each of them once. Risk may pause it; only governance may resume it.
contract SpikeDailyAccrual is SpikeClock, AccessManaged, Pausable {
    uint256 public immutable amountPerDay;
    uint256 public lastRunDay;
    uint256 public accrued;

    event DayRun(uint256 indexed day, uint256 amount);

    constructor(address manager, uint256 genesis_, uint256 amountPerDay_) SpikeClock(genesis_) AccessManaged(manager) {
        amountPerDay = amountPerDay_;
    }

    /// @dev Does nothing when no day is due, so the scheduler may trigger it freely.
    function runDue() external restricted whenNotPaused {
        uint256 today = businessDay();
        uint256 last = lastRunDay;
        if (today == last) return;

        uint256 total = accrued;
        for (uint256 day = last + 1; day <= today; ++day) {
            total += amountPerDay;
            emit DayRun(day, amountPerDay);
        }
        accrued = total;
        lastRunDay = today;
    }

    function pause() external restricted {
        _pause();
    }

    function unpause() external restricted {
        _unpause();
    }
}

/// @dev A channel's daily cap, as a rolling window over block time with one counter per key.
contract SpikeDailyLimit is AccessManaged {
    using RateLimiter for RateLimiter.SlidingWindow;

    RateLimiter.SlidingWindow private _limiter;

    constructor(address manager, uint208 limit) AccessManaged(manager) {
        _limiter.updateSettings(1 days, limit);
    }

    function available(bytes32 key) external view returns (uint256) {
        return _limiter.available(key);
    }

    function spend(bytes32 key, uint256 amount) external restricted {
        _limiter.consume(key, amount);
    }
}

/// @dev The rejected model: a business date the scheduler stores and advances on its own. It moves,
/// but nothing that reads block time moves with it.
contract SpikeStoredDate is AccessManaged {
    uint256 public businessDay;

    constructor(address manager) AccessManaged(manager) {}

    function advance() external restricted {
        ++businessDay;
    }
}
