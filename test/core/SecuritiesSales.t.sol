// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {SecuritiesSales} from "../../contracts/core/SecuritiesSales.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the securities sales module against open question 27 in docs/plan.md: treasury instructs,
/// finance approves, and only the custodian's signed settlement confirmation books the sale, securities
/// down and the settlement account up in one entry, once and for the sale's amount.
contract SecuritiesSalesTest is BankFixture {
    uint256 constant SOLD = 400_000 * HKD;

    address dealer = _staff("dealer");
    address controller = _staff("controller");
    uint256 confirmations;

    function setUp() public override {
        super.setUp();
        _grantStaff(dealer, Roles.TREASURY);
        _grantStaff(controller, Roles.FINANCE);
    }

    function test_Settle_MovesSecuritiesIntoTheSettlementAccount() public {
        int256 securities = ledger.balanceOf(GeneralLedger.Account.Securities);
        int256 settlement = ledger.balanceOf(GeneralLedger.Account.Settlement);
        uint256 supply = token.totalSupply();
        bytes32 ref = _approved(SOLD);

        SecuritiesSales.SettlementConfirmation memory m = _confirmation(ref, SOLD);
        vm.expectEmit(address(sales));
        emit SecuritiesSales.SaleSettled(ref, SOLD, m.settledAt, m.documentHash);
        sales.settle(m, _sign(custodianKey, m));

        assertEq(ledger.balanceOf(GeneralLedger.Account.Securities), securities - int256(SOLD));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Settlement), settlement + int256(SOLD));
        assertEq(token.totalSupply(), supply, "a sale moves no deposits");
        assertEq(uint8(sales.sale(ref).status), uint8(SecuritiesSales.Status.Settled));
    }

    function test_Instruct_OnlyTreasury() public {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, controller));
        sales.instruct(SOLD);
    }

    function test_Instruct_RefusesZero() public {
        vm.prank(dealer);
        vm.expectRevert(SecuritiesSales.ZeroAmount.selector);
        sales.instruct(0);
    }

    function test_Approve_OnlyFinance() public {
        vm.prank(dealer);
        bytes32 ref = sales.instruct(SOLD);
        vm.prank(dealer);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, dealer));
        sales.approve(ref);
    }

    function test_Approve_OnlyAnInstructedSale() public {
        bytes32 ref = _approved(SOLD);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(SecuritiesSales.NotAwaiting.selector, ref, SecuritiesSales.Status.Approved));
        sales.approve(ref);
    }

    function test_Settle_NotBeforeFinanceApproves() public {
        vm.prank(dealer);
        bytes32 ref = sales.instruct(SOLD);
        SecuritiesSales.SettlementConfirmation memory m = _confirmation(ref, SOLD);
        bytes memory sig = _sign(custodianKey, m);
        vm.expectRevert(abi.encodeWithSelector(SecuritiesSales.UnknownSale.selector, ref, SOLD));
        sales.settle(m, sig);
    }

    function test_Settle_OnlyTheCustodiansSignature() public {
        bytes32 ref = _approved(SOLD);
        SecuritiesSales.SettlementConfirmation memory m = _confirmation(ref, SOLD);
        bytes memory sig = _sign(clearingKey, m);
        vm.expectRevert(SecuritiesSales.InvalidPartnerSignature.selector);
        sales.settle(m, sig);
    }

    function test_Settle_OnlyTheSalesAmount() public {
        bytes32 ref = _approved(SOLD);
        SecuritiesSales.SettlementConfirmation memory m = _confirmation(ref, SOLD + 1);
        bytes memory sig = _sign(custodianKey, m);
        vm.expectRevert(abi.encodeWithSelector(SecuritiesSales.UnknownSale.selector, ref, SOLD + 1));
        sales.settle(m, sig);
    }

    function test_Settle_Once() public {
        bytes32 ref = _approved(SOLD);
        SecuritiesSales.SettlementConfirmation memory m = _confirmation(ref, SOLD);
        bytes memory sig = _sign(custodianKey, m);
        sales.settle(m, sig);
        vm.expectRevert(abi.encodeWithSelector(SecuritiesSales.UnknownSale.selector, ref, SOLD));
        sales.settle(m, sig);
    }

    function test_Settle_NoMoreThanTheHolding() public {
        uint256 holding = uint256(ledger.balanceOf(GeneralLedger.Account.Securities));
        bytes32 ref = _approved(holding + 1);
        SecuritiesSales.SettlementConfirmation memory m = _confirmation(ref, holding + 1);
        bytes memory sig = _sign(custodianKey, m);
        vm.expectRevert(abi.encodeWithSelector(GeneralLedger.NegativeAsset.selector, GeneralLedger.Account.Securities, -int256(1)));
        sales.settle(m, sig);
    }

    function _approved(uint256 amount) private returns (bytes32 ref) {
        vm.prank(dealer);
        ref = sales.instruct(amount);
        vm.prank(controller);
        sales.approve(ref);
    }

    function _confirmation(bytes32 ref, uint256 amount) private returns (SecuritiesSales.SettlementConfirmation memory) {
        return SecuritiesSales.SettlementConfirmation(ref, amount, block.timestamp, keccak256(abi.encode("sese.025", ++confirmations)));
    }

    function _sign(uint256 key, SecuritiesSales.SettlementConfirmation memory m) private view returns (bytes memory) {
        return _signP256(key, sales.hashSettlementConfirmation(m));
    }
}
