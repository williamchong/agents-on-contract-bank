// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {Rates} from "../../contracts/core/Rates.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the rates contract against open questions 24 and 28 in docs/plan.md and the rate rows of
/// the permission matrix in docs/roles.md: treasury proposes the savings and loan rates and risk the
/// allowance rates, each under its paper, and only governance applies a proposal, by that paper.
contract RatesTest is BankFixture {
    bytes32 constant PAPER = keccak256("pricing paper");

    address treasurer = makeAddr("treasurer");
    address riskOfficer = makeAddr("risk officer");

    function setUp() public override {
        super.setUp();
        vm.startPrank(address(staffRoles));
        manager.grantRole(Roles.TREASURY, treasurer, 0);
        manager.grantRole(Roles.RISK, riskOfficer, 0);
        vm.stopPrank();
    }

    function test_Opening_TheDemoRates() public view {
        (uint256 savings, uint256 loan) = rates.products();
        assertEq(savings, SAVINGS_RATE_BPS);
        assertEq(loan, LOAN_RATE_BPS);
        (uint256 performing, uint256 arrears, uint256 defaulted) = rates.allowance();
        assertEq(performing, PERFORMING_ALLOWANCE_BPS);
        assertEq(arrears, ARREARS_ALLOWANCE_BPS);
        assertEq(defaulted, DEFAULT_ALLOWANCE_BPS);
    }

    function test_ProductRates_ProposedByTreasuryAppliedByGovernance() public {
        vm.prank(treasurer);
        rates.proposeProductRates(Rates.ProductRates(125, 650), PAPER);
        (, uint256 loan) = rates.products();
        assertEq(loan, LOAN_RATE_BPS, "a proposal waits for governance");

        _govern(address(rates), abi.encodeCall(Rates.applyProductRates, (PAPER)));
        (uint256 savings, uint256 applied) = rates.products();
        assertEq(savings, 125);
        assertEq(applied, 650);
        assertEq(rates.productsPaper(), bytes32(0), "nothing waits once applied");
    }

    function test_AllowanceRates_ProposedByRiskAppliedByGovernance() public {
        vm.prank(riskOfficer);
        rates.proposeAllowanceRates(Rates.AllowanceRates(150, 1_500, 7_000), PAPER);
        _govern(address(rates), abi.encodeCall(Rates.applyAllowanceRates, (PAPER)));
        (uint256 performing, uint256 arrears, uint256 defaulted) = rates.allowance();
        assertEq(performing, 150);
        assertEq(arrears, 1_500);
        assertEq(defaulted, 7_000);
    }

    /// @dev Governance applies what it reviewed: a proposal replaced while it waits is not applied.
    function test_Apply_OnlyThePaperProposed() public {
        vm.prank(treasurer);
        rates.proposeProductRates(Rates.ProductRates(125, 650), PAPER);
        bytes memory data = abi.encodeCall(Rates.applyProductRates, (PAPER));
        bytes32 salt = _schedule(address(rates), data, _quorum());
        bytes32 other = keccak256("another paper");
        vm.prank(treasurer);
        rates.proposeProductRates(Rates.ProductRates(0, 2_000), other);

        vm.warp(block.timestamp + GOVERNANCE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(Rates.NotThePaperProposed.selector, PAPER, other));
        timelock.execute(address(rates), 0, data, bytes32(0), salt);
    }

    function test_Apply_NothingProposed() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Rates.NotThePaperProposed.selector, bytes32(0), bytes32(0)));
        rates.applyProductRates(bytes32(0));
    }

    function test_Propose_RefusesNoPaperAndRatesAboveWhole() public {
        vm.startPrank(treasurer);
        vm.expectRevert(Rates.NoPaper.selector);
        rates.proposeProductRates(Rates.ProductRates(100, 600), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Rates.RateAboveWhole.selector, 10_001));
        rates.proposeProductRates(Rates.ProductRates(100, 10_001), PAPER);
        vm.stopPrank();
    }

    function test_Roles_EachProposesOnlyItsOwnAndNeitherApplies() public {
        vm.startPrank(treasurer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, treasurer));
        rates.proposeAllowanceRates(Rates.AllowanceRates(0, 0, 0), PAPER);
        rates.proposeProductRates(Rates.ProductRates(100, 600), PAPER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, treasurer));
        rates.applyProductRates(PAPER);
        vm.stopPrank();

        vm.prank(riskOfficer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, riskOfficer));
        rates.proposeProductRates(Rates.ProductRates(100, 600), PAPER);
    }
}
