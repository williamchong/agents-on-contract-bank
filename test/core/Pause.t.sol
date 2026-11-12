// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks pausing against open question 31 in docs/plan.md, the pause and resume rows of
/// docs/roles.md and the pause and resume scenario in docs/scenarios.md: risk pauses the deposit token,
/// which stops every movement, the bank's own included; risk cannot resume; only governance resumes,
/// after its time lock, and money moves again.
contract PauseTest is BankFixture {
    function test_Pause_StopsEveryMovement() public {
        _pauseBank();
        assertTrue(token.paused());

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1);

        // The bank's own movements too: creating money, destroying it and forcing a transfer.
        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](1);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Cash, 100);
        vm.prank(treasury);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ledger.postWithMint(alice, 100, lines, "cash in");

        address enforcer = makeAddr("enforcer");
        vm.prank(governance);
        manager.grantRole(Roles.ENFORCER, enforcer, 0);
        vm.prank(enforcer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.forcedTransfer(alice, pending, 1);
    }

    function test_Pause_OnlyRisk() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, alice));
        token.pause();
    }

    function test_Resume_NotByRisk() public {
        _pauseBank();
        address risk = _risk();
        vm.prank(risk);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, risk));
        token.unpause();
    }

    function test_Resume_ByGovernanceAfterItsTimeLock() public {
        _pauseBank();
        _resumeBank();
        assertFalse(token.paused());
        vm.prank(alice);
        token.transfer(bob, 1);
    }
}
