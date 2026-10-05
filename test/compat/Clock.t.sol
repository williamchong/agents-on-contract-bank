// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";
import {SpikeDailyAccrual, SpikeDailyLimit, SpikeStoredDate} from "../../contracts/spike/SpikeClock.sol";
import {SpikeDepositToken} from "../../contracts/spike/SpikeDepositToken.sol";

/// @dev Checks that one jump of block time moves the business day together with everything else
/// that reads time: time locks, access manager delays, EIP-3009 validity windows and rate limits.
/// A stored business date is shown to leave them behind. See open question 11 in docs/plan.md.
contract ClockTest is Test {
    uint64 constant SCHEDULER = 1;
    uint64 constant RISK = 2;
    uint64 constant GOVERNANCE = 3;

    uint256 constant PER_DAY = 10;

    string constant CONTENTS_TYPE =
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)";

    AccessManager manager;
    TimelockController timelock;
    SpikeDailyAccrual accrual;

    address scheduler = makeAddr("scheduler");
    address risk = makeAddr("risk");
    address officers = makeAddr("officers");
    address bob = makeAddr("bob");

    function setUp() public {
        manager = new AccessManager(address(this));
        accrual = new SpikeDailyAccrual(address(manager), block.timestamp, PER_DAY);

        address[] memory proposers = new address[](1);
        proposers[0] = officers;
        // The zero address as executor lets anyone carry out a ready operation.
        address[] memory executors = new address[](1);
        timelock = new TimelockController(1 days, proposers, executors, address(0));

        _setRole(accrual.runDue.selector, SCHEDULER);
        _setRole(accrual.pause.selector, RISK);
        _setRole(accrual.unpause.selector, GOVERNANCE);
        manager.grantRole(SCHEDULER, scheduler, 0);
        manager.grantRole(RISK, risk, 0);
        manager.grantRole(GOVERNANCE, address(timelock), 0);
    }

    // The rejected model: a stored business date

    function test_StoredDate_LeavesTimeLockBehind() public {
        SpikeStoredDate stored = new SpikeStoredDate(address(manager));
        bytes32 id = _scheduleResume();

        stored.advance();

        assertEq(stored.businessDay(), 1);
        assertEq(accrual.businessDay(), 0);
        assertFalse(timelock.isOperationReady(id));
    }

    // The business day from block time

    function test_BusinessDay_FollowsBlockTime() public {
        skip(1 days - 1);
        assertEq(accrual.businessDay(), 0);
        skip(1);
        assertEq(accrual.businessDay(), 1);
    }

    function test_Jump_OpensTimeLock() public {
        bytes32 id = _scheduleResume();
        assertFalse(timelock.isOperationReady(id));

        skip(1 days);
        assertTrue(timelock.isOperationReady(id));
    }

    function test_Jump_ReleasesAccessManagerDelay() public {
        address delayed = makeAddr("delayed");
        manager.grantRole(SCHEDULER, delayed, 1 days);
        bytes memory data = abi.encodeCall(accrual.runDue, ());

        vm.startPrank(delayed);
        (bytes32 id, ) = manager.schedule(address(accrual), data, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        manager.execute(address(accrual), data);

        skip(1 days);
        manager.execute(address(accrual), data);
        vm.stopPrank();

        assertEq(accrual.accrued(), PER_DAY);
    }

    function test_Jump_ExpiresAuthorisation() public {
        SpikeDepositToken token = new SpikeDepositToken(address(manager));
        // Not "alice": that well-known test key carries an EIP-7702 delegation on Base Sepolia, so
        // its signature would be checked by the delegate's code, not as a plain key.
        (address alice, uint256 aliceKey) = makeAddrAndKey("clock-alice");
        token.allowUser(alice);
        token.allowUser(bob);
        token.mint(alice, 100);

        uint256 validBefore = block.timestamp + 1 days;
        bytes memory sig = _authorisation(token, aliceKey, 30, validBefore);

        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009InvalidAuthorizationTime.selector, 0, validBefore));
        token.transferWithAuthorization(alice, bob, 30, 0, validBefore, 0, sig);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_Jump_RefillsDailyLimit() public {
        SpikeDailyLimit limit = new SpikeDailyLimit(address(manager), 100);
        bytes32 key = keccak256("customer/app");

        limit.spend(key, 100);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        limit.spend(key, 1);

        skip(1 days);
        assertEq(limit.available(key), 100);
    }

    // Scheduled work

    function test_RunDue_OncePerDay() public {
        skip(1 days);
        vm.startPrank(scheduler);
        accrual.runDue();
        accrual.runDue();
        vm.stopPrank();

        assertEq(accrual.accrued(), PER_DAY);
    }

    function test_RunDue_CatchesUpEachDayAfterJump() public {
        skip(3 days);
        for (uint256 day = 1; day <= 3; ++day) {
            vm.expectEmit(address(accrual));
            emit SpikeDailyAccrual.DayRun(day, PER_DAY);
        }
        vm.prank(scheduler);
        accrual.runDue();

        assertEq(accrual.accrued(), 3 * PER_DAY);
        assertEq(accrual.lastRunDay(), 3);
    }

    function test_RunDue_OnlyScheduler() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        accrual.runDue();
    }

    // Pause and resume

    function test_PauseAndResume_ResumeWaitsForTimeLock() public {
        vm.prank(risk);
        accrual.pause();

        skip(1 days);
        vm.prank(scheduler);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        accrual.runDue();

        vm.prank(risk);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, risk));
        accrual.unpause();

        bytes32 id = _scheduleResume();
        bytes memory data = _resumeData();
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(1 << uint8(TimelockController.OperationState.Ready))
            )
        );
        timelock.execute(address(accrual), 0, data, 0, 0);

        skip(1 days);
        timelock.execute(address(accrual), 0, data, 0, 0);
        assertFalse(accrual.paused());

        // The days missed while paused are run on the first trigger after the resume.
        vm.prank(scheduler);
        accrual.runDue();
        assertEq(accrual.accrued(), 2 * PER_DAY);
    }

    // Helpers

    function _setRole(bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(address(accrual), selectors, role);
    }

    function _resumeData() private view returns (bytes memory) {
        return abi.encodeCall(accrual.unpause, ());
    }

    function _scheduleResume() private returns (bytes32 id) {
        bytes memory data = _resumeData();
        vm.prank(officers);
        timelock.schedule(address(accrual), 0, data, 0, 0, 1 days);
        return timelock.hashOperation(address(accrual), 0, data, 0, 0);
    }

    /// @dev An EIP-3009 authorisation signed directly by a key, paying bob from its address.
    function _authorisation(
        SpikeDepositToken token,
        uint256 key,
        uint256 value,
        uint256 validBefore
    ) private view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(bytes(CONTENTS_TYPE)),
                vm.addr(key),
                bob,
                value,
                0,
                validBefore,
                bytes32(0)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toTypedDataHash(_separator(token), structHash));
        return abi.encodePacked(r, s, v);
    }

    function _separator(SpikeDepositToken token) private view returns (bytes32) {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt, ) = token
            .eip712Domain();
        return MessageHashUtils.toDomainSeparator(fields, name, version, chainId, verifying, salt);
    }
}
