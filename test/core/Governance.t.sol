// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {KeyTypes, MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks governance as docs/roles.md describes it: three of the four officers sign a
/// decision, the time lock holds it for its delay, and only then is it carried out.
contract GovernanceTest is BankFixture {
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    function test_TimeLockHoldsTheAdminRoles() public view {
        assertTrue(_holds(Roles.ADMIN, governance) && _holds(Roles.GOVERNANCE, governance));
        assertFalse(_holds(Roles.ADMIN, address(this)) || _holds(Roles.GOVERNANCE, address(officers)));
    }

    function test_ThreeOfFourCarryADecision() public {
        _govern(address(token), abi.encodeCall(DepositToken.allowUser, (carol)));
        assertTrue(token.canTransact(carol));
    }

    function test_AnyThreeOfFour() public {
        uint256[] memory keys = new uint256[](3);
        keys[0] = officerKeys[3];
        keys[1] = officerKeys[1];
        keys[2] = officerKeys[2];
        bytes memory data = abi.encodeCall(DepositToken.allowUser, (carol));
        bytes32 salt = _schedule(address(token), data, keys);
        vm.warp(block.timestamp + GOVERNANCE_DELAY);
        timelock.execute(address(token), 0, data, bytes32(0), salt);
        assertTrue(token.canTransact(carol));
    }

    function test_TwoOfFourRefused() public {
        uint256[] memory keys = new uint256[](2);
        keys[0] = officerKeys[0];
        keys[1] = officerKeys[1];
        bytes memory executionData = _scheduleBatch(abi.encodeCall(DepositToken.allowUser, (carol)));
        bytes memory sig = _signExecution(officers, executionData, keys);
        vm.expectRevert(MultiSignerAccount.InvalidExecutionSignature.selector);
        officers.executeSigned(executionData, sig);
    }

    function test_OneOfficerTwiceRefused() public {
        uint256[] memory keys = new uint256[](3);
        keys[0] = officerKeys[0];
        keys[1] = officerKeys[1];
        keys[2] = officerKeys[0];
        bytes memory executionData = _scheduleBatch(abi.encodeCall(DepositToken.allowUser, (carol)));
        bytes memory sig = _signExecution(officers, executionData, keys);
        vm.expectRevert(MultiSignerAccount.InvalidExecutionSignature.selector);
        officers.executeSigned(executionData, sig);
    }

    function test_SignedBatchUsedOnce() public {
        bytes memory executionData = _scheduleBatch(abi.encodeCall(DepositToken.allowUser, (carol)));
        bytes memory sig = _signExecution(officers, executionData, _quorum());
        officers.executeSigned(executionData, sig);
        vm.expectRevert(MultiSignerAccount.InvalidExecutionSignature.selector);
        officers.executeSigned(executionData, sig);
    }

    function test_DecisionWaitsForTheDelay() public {
        bytes memory data = abi.encodeCall(DepositToken.allowUser, (carol));
        bytes32 salt = _schedule(address(token), data, _quorum());
        bytes32 id = timelock.hashOperation(address(token), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + GOVERNANCE_DELAY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(1 << uint8(TimelockController.OperationState.Ready))
            )
        );
        timelock.execute(address(token), 0, data, bytes32(0), salt);
        assertFalse(token.canTransact(carol));
    }

    function test_OnlyTheOfficersSchedule() public {
        bytes32 proposer = timelock.PROPOSER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, proposer));
        timelock.schedule(address(token), 0, "", bytes32(0), bytes32(0), GOVERNANCE_DELAY);
    }

    function test_TheTimeLockCannotBeHurried() public {
        vm.prank(address(officers));
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 1 hours, GOVERNANCE_DELAY)
        );
        timelock.schedule(address(token), 0, "", bytes32(0), bytes32(0), 1 hours);
    }

    function test_OfficerKeysOnlyOfTheAcceptedType() public {
        bytes[] memory plain = new bytes[](1);
        plain[0] = abi.encodePacked(makeAddr("plain key"));
        address[] memory verifiers = new address[](1);
        verifiers[0] = address(p256);
        vm.expectRevert(abi.encodeWithSelector(KeyTypes.KeyTypeRefused.selector, plain[0]));
        new MultiSignerAccount(verifiers, plain, 1);
    }

    function test_SignersChangeOnlyByTheAccount() public {
        vm.prank(stranger);
        vm.expectRevert();
        officers.addSigners(_signers(_quorum()));
    }

    /// @dev The officers' batch scheduling `data` on the token.
    function _scheduleBatch(bytes memory data) private view returns (bytes memory) {
        Execution[] memory batch = new Execution[](1);
        batch[0] = Execution(
            address(timelock),
            0,
            abi.encodeCall(TimelockController.schedule, (address(token), 0, data, bytes32(0), bytes32(0), GOVERNANCE_DELAY))
        );
        return ERC7579Utils.encodeBatch(batch);
    }
}
