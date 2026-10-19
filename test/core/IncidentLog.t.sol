// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {IncidentLog} from "../../contracts/core/IncidentLog.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the incident log against open question 22 in docs/plan.md: finance records what it reported
/// to the regulator, with the report's hash, and the record names who reported it.
contract IncidentLogTest is BankFixture {
    bytes32 constant KIND = "statement mismatch";
    bytes32 constant SUBJECT = keccak256("camt.053 7");
    bytes32 constant REPORT = keccak256("the report sent to the regulator");

    address finance;

    function setUp() public override {
        super.setUp();
        finance = _staff("finance");
        _grantStaff(finance, Roles.FINANCE);
    }

    function test_Report_RecordsWhoReportedWhat() public {
        vm.expectEmit(true, true, true, true, address(incidents));
        emit IncidentLog.IncidentReported(1, KIND, SUBJECT, REPORT, finance);
        vm.prank(finance);
        assertEq(incidents.report(KIND, SUBJECT, REPORT), 1);
        assertEq(incidents.incidentCount(), 1);
    }

    function test_Report_OnlyByFinance() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        incidents.report(KIND, SUBJECT, REPORT);
    }

    function test_Report_NeedsTheReport() public {
        vm.prank(finance);
        vm.expectRevert(IncidentLog.NoReport.selector);
        incidents.report(KIND, SUBJECT, 0);
    }
}
