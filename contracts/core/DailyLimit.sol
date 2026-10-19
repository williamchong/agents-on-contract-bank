// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev Daily limits that reset at midnight Hong Kong time, as a bank's daily card and app limits
/// do. The day is worked out from block time, the clock every time lock and signature window reads,
/// so a jump in time moves it too. Each limiter keeps one counter per key, the account and the
/// channel. OpenZeppelin's RateLimiter offers only rolling windows. See open question 17 in
/// docs/plan.md.
library DailyLimit {
    using SafeCast for uint256;

    /// @dev Hong Kong keeps eight hours ahead of UTC all year.
    uint256 internal constant HONG_KONG_OFFSET = 8 hours;

    struct Usage {
        uint64 day;
        uint192 used;
    }

    struct Limiter {
        mapping(bytes32 key => Usage) usage;
    }

    error DailyLimitExceeded(bytes32 key, uint256 amount, uint256 available);

    /// @dev Days since the epoch, in Hong Kong time.
    function today() internal view returns (uint64) {
        return dayOf(block.timestamp);
    }

    /// @dev The Hong Kong day that block time `timestamp` falls on.
    function dayOf(uint256 timestamp) internal pure returns (uint64) {
        return uint64((timestamp + HONG_KONG_OFFSET) / 1 days);
    }

    function used(Limiter storage self, bytes32 key) internal view returns (uint256) {
        Usage memory u = self.usage[key];
        return u.day == today() ? u.used : 0;
    }

    function available(Limiter storage self, bytes32 key, uint256 limit) internal view returns (uint256) {
        uint256 spent = used(self, key);
        return limit > spent ? limit - spent : 0;
    }

    /// @dev Counts `amount` against today's `limit` for `key`, or reverts if it would go over.
    function consume(Limiter storage self, bytes32 key, uint256 amount, uint256 limit) internal {
        uint256 spent = used(self, key);
        if (spent + amount > limit) revert DailyLimitExceeded(key, amount, available(self, key, limit));
        self.usage[key] = Usage(today(), (spent + amount).toUint192());
    }

    /// @dev Gives back `amount` counted on `day` that never left, such as a failed dispense. Usage
    /// from an earlier day has already lapsed, so there is nothing to give back, and never more than is
    /// counted, so a release can never stop the movement that triggers it.
    function release(Limiter storage self, bytes32 key, uint256 amount, uint64 day) internal {
        Usage storage u = self.usage[key];
        if (u.day != day) return;
        uint192 back = amount > u.used ? u.used : amount.toUint192();
        u.used -= back;
    }
}
