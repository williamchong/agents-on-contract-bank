// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DailyLimit} from "../../contracts/core/DailyLimit.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {MultiSignerAccount} from "../../contracts/core/MultiSignerAccount.sol";
import {CashOperations} from "../../contracts/core/CashOperations.sol";
import {BranchApprovals} from "../../contracts/core/BranchApprovals.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the cash module against the cash rows of the permission matrix in docs/roles.md, the
/// cash withdrawal flow in docs/architecture.md and the ATM fails to dispense scenario in
/// docs/scenarios.md: deposits at the counter within the drawer limit, ATM withdrawals by card held
/// until the dispense is confirmed, failed or settled at the next count, daily limits that reset at
/// midnight Hong Kong time, and moves, banking and counts under dual control. The module's split of
/// the cash always sums to the ledger's cash account, and the books balance after every step.
contract CashOperationsTest is BankFixture {
    uint64 constant TELLER_1 = 101;
    uint64 constant SUPERVISOR_1 = 102;
    uint64 constant CUSTODIAN_1 = 104;
    uint64 constant TELLER_2 = 201;
    uint64 constant SUPERVISOR_2 = 202;
    uint256 constant WITHDRAWAL = 3_000 * HKD;

    address custodian;
    address supervisor1;
    address supervisor2;
    address teller2;
    address atm2 = makeAddr("atm2");
    address stranger = makeAddr("stranger");
    /// @dev A customer whose account has a card among its signers.
    MultiSignerAccount carol;
    uint256 cardKey = _key("carol's card");

    CashHandler handler;

    function setUp() public override {
        super.setUp();
        custodian = _staff("custodian");
        supervisor1 = _staff("supervisor1");
        supervisor2 = _staff("supervisor2");
        teller2 = _staff("teller2");
        // Branch roles and ATM enrolment go through their own approvals; that path is checked in
        // StaffRolesTest, so they are granted directly here.
        vm.startPrank(address(staffRoles));
        manager.grantRole(TELLER_1, teller1, 0);
        manager.grantRole(CUSTODIAN_1, custodian, 0);
        manager.grantRole(SUPERVISOR_1, supervisor1, 0);
        manager.grantRole(SUPERVISOR_2, supervisor2, 0);
        manager.grantRole(TELLER_2, teller2, 0);
        manager.grantRole(Roles.ATM, atm1, 0);
        manager.grantRole(Roles.ATM, atm2, 0);
        vm.stopPrank();

        uint256[] memory keys = new uint256[](1);
        keys[0] = cardKey;
        carol = new MultiSignerAccount(_verifiers(), _signers(keys), 1);
        vm.prank(governance);
        token.allowUser(address(carol));
        vm.prank(alice);
        token.transfer(address(carol), 20_000 * HKD);

        handler = new CashHandler(this, cash, address(carol), atm1, _vault(1), _drawer(1, teller1), _atm(1, atm1));
        targetContract(address(handler));
    }

    /// @dev Over any run of deposits, withdrawals, dispenses, failures, timeouts, moves, banking and
    /// counts, the module's split sums to the ledger's cash, it holds exactly the withdrawals still
    /// waiting, and the books balance.
    function invariant_SplitSumsToLedgerCash() public view {
        assertEq(_split(), _ledgerCash(), "split sums to ledger cash");
        assertEq(token.balanceOf(address(cash)), cash.inFlight(_id(_atm(1, atm1))), "module holds what is in flight");
        _assertBooksBalance();
    }

    // Opening

    function test_Opening_SplitAsRolesSays() public view {
        assertEq(cash.cashAt(_id(_vault(1))), 250_000 * HKD);
        assertEq(cash.cashAt(_id(_drawer(1, teller1))), 50_000 * HKD);
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 200_000 * HKD);
        assertEq(_split(), _ledgerCash());
    }

    function test_Opening_OnceEvenWithTheCashAllBanked() public {
        _approved(_proposeMove(_drawer(1, teller1), _vault(1), 50_000 * HKD));
        _approved(_proposeMove(_atm(1, atm1), _vault(1), 200_000 * HKD));
        _approved(_proposeBanking(500_000 * HKD));
        assertEq(_ledgerCash(), 0);
        vm.prank(governance);
        vm.expectRevert(CashOperations.AlreadyOpened.selector);
        cash.openCash(new CashOperations.Location[](0), new uint256[](0));
    }

    function test_Opening_Once() public {
        CashOperations.Location[] memory at = new CashOperations.Location[](1);
        at[0] = _vault(1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.prank(governance);
        vm.expectRevert(CashOperations.AlreadyOpened.selector);
        cash.openCash(at, amounts);
    }

    function test_ModuleIsABankOwnedBookkeeper() public view {
        assertTrue(token.canTransact(address(cash)));
        assertTrue(_holds(Roles.BOOKKEEPER, address(cash)));
    }

    // At the counter

    function test_Deposit_CreatesTheCustomersMoneyAgainstCash() public {
        uint256 before = token.balanceOf(alice);
        int256 ledgerCash = _ledgerCash();
        uint256 drawer = cash.cashAt(_id(_drawer(1, teller1)));

        vm.expectEmit(false, true, true, false, address(cash));
        emit CashOperations.CashDeposited(bytes32(0), alice, teller1, bytes32(0), 0);
        _deposit(alice, 10_000 * HKD);

        assertEq(token.balanceOf(alice), before + 10_000 * HKD);
        assertEq(_ledgerCash(), ledgerCash + int256(10_000 * HKD));
        assertEq(cash.cashAt(_id(_drawer(1, teller1))), drawer + 10_000 * HKD);
        _assertBooksBalance();
    }

    function test_Deposit_RefusedWithoutTheBranchsTellerRole() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotTeller.selector, stranger, 1));
        cash.deposit(1, alice, HKD);
        // A teller of the other branch cannot act at this one.
        vm.prank(teller2);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.NotTeller.selector, teller2, 1));
        cash.deposit(1, alice, HKD);
    }

    function test_Deposit_RefusedOverTheDrawerLimit() public {
        uint256 inDrawer = cash.cashAt(_id(_drawer(1, teller1)));
        uint256 tooMuch = DRAWER_LIMIT - inDrawer + 1;
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.DrawerLimit.selector, inDrawer, tooMuch, DRAWER_LIMIT));
        cash.deposit(1, alice, tooMuch);
    }

    function test_Deposit_RefusedForACustomerNotOnboarded() public {
        vm.prank(teller1);
        vm.expectRevert();
        cash.deposit(1, stranger, HKD);
    }

    function test_Deposit_AtTheReportThresholdTellsCompliance() public {
        // Empty the drawer into the vault first, so a deposit at the threshold fits within the drawer limit.
        _approved(_proposeMove(_drawer(1, teller1), _vault(1), 50_000 * HKD));

        vm.expectEmit(false, true, false, true, address(cash));
        emit CashOperations.CashReported(bytes32(0), alice, CASH_REPORT_THRESHOLD);
        _deposit(alice, CASH_REPORT_THRESHOLD);
    }

    function test_Deposit_BelowTheReportThresholdTellsNoOne() public {
        vm.recordLogs();
        _deposit(alice, CASH_REPORT_THRESHOLD - 50_000 * HKD - 1);
        assertEq(_countLogs(CashOperations.CashReported.selector), 0);
    }

    // At the ATM

    function test_Atm_HoldsTheAmountUntilDispensed() public {
        uint256 before = token.balanceOf(address(carol));
        bytes32 ref = _withdraw(WITHDRAWAL);

        assertEq(token.balanceOf(address(carol)), before - WITHDRAWAL);
        assertEq(token.balanceOf(address(cash)), WITHDRAWAL);
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 200_000 * HKD, "the machine's cash moves only on the dispense");
        assertEq(uint8(cash.withdrawal(ref).status), uint8(CashOperations.WithdrawalStatus.Held));
        _assertBooksBalance();
    }

    function test_Atm_ConfirmedDispenseDestroysTheTokensAgainstCash() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        uint256 supply = token.totalSupply();
        int256 ledgerCash = _ledgerCash();

        vm.prank(atm1);
        cash.confirmDispense(ref);

        assertEq(token.totalSupply(), supply - WITHDRAWAL);
        assertEq(_ledgerCash(), ledgerCash - int256(WITHDRAWAL));
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 200_000 * HKD - WITHDRAWAL);
        assertEq(token.balanceOf(address(cash)), 0);
        _assertBooksBalance();
    }

    /// @dev The ATM fails to dispense, first run: the amount waits as pending, then returns.
    function test_Atm_ReportedFailureReturnsTheAmount() public {
        uint256 before = token.balanceOf(address(carol));
        bytes32 ref = _withdraw(WITHDRAWAL);

        vm.prank(atm1);
        cash.reportFailure(ref);

        assertEq(token.balanceOf(address(carol)), before, "the customer is whole");
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 200_000 * HKD, "ATM cash unchanged");
        assertEq(cash.atmAvailable(address(carol)), ATM_LIMIT, "the limit is given back");
        _assertBooksBalance();
    }

    function test_Atm_RefusedOverTheDailyLimit() public {
        _withdraw(WITHDRAWAL);
        bytes32 key = keccak256(abi.encode(address(carol), cash.ATM_CHANNEL()));
        BranchApprovals.CardAuthorisation memory card = _card(WITHDRAWAL, bytes32(uint256(1)));
        vm.prank(atm1);
        vm.expectRevert(
            abi.encodeWithSelector(DailyLimit.DailyLimitExceeded.selector, key, WITHDRAWAL, ATM_LIMIT - WITHDRAWAL)
        );
        cash.withdrawAtAtm(1, card);
    }

    function test_Atm_LimitResetsAtMidnightHongKongTime() public {
        // 23:59 in Hong Kong is 15:59 UTC.
        vm.warp(_nextUtcDay() + 15 hours + 59 minutes);
        _withdraw(ATM_LIMIT);
        assertEq(cash.atmAvailable(address(carol)), 0);

        vm.warp(block.timestamp + 1 minutes);
        assertEq(cash.atmAvailable(address(carol)), ATM_LIMIT, "a new day in Hong Kong");
        _withdrawWith(_card(WITHDRAWAL, bytes32(uint256(1))));
    }

    function test_Atm_LimitIsNotRolling() public {
        // Just after midnight in Hong Kong, the whole limit is spent; it stays spent until the next midnight.
        vm.warp(_nextUtcDay() + 16 hours + 1 minutes);
        _withdraw(ATM_LIMIT);
        vm.warp(block.timestamp + 23 hours);
        assertEq(cash.atmAvailable(address(carol)), 0);
    }

    function test_Atm_UsedAuthorisationRefused() public {
        BranchApprovals.CardAuthorisation memory card = _card(1_000 * HKD, 0);
        _withdrawWith(card);
        vm.prank(atm1);
        vm.expectRevert();
        cash.withdrawAtAtm(1, card);
    }

    function test_Atm_AnotherCardsSignatureRefused() public {
        BranchApprovals.CardAuthorisation memory card = _card(WITHDRAWAL, 0);
        card.signature = _cardSignature(_key("stolen card"), address(carol), address(cash), WITHDRAWAL, card.nonce);
        vm.prank(atm1);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        cash.withdrawAtAtm(1, card);
    }

    function test_Atm_AuthorisationForOneAtmRefusedAtAnother() public {
        _approved(_proposeMove(_vault(1), _atm(1, atm2), 10_000 * HKD));
        BranchApprovals.CardAuthorisation memory card = _card(WITHDRAWAL, 0);
        vm.prank(atm2);
        vm.expectRevert(abi.encodeWithSelector(BranchApprovals.AuthorisedForAnotherIntent.selector, card.nonce));
        cash.withdrawAtAtm(1, card);
    }

    function test_Atm_FrozenMoneyCannotBeWithdrawn() public {
        address compliance = _staff("compliance");
        _grantStaff(compliance, Roles.COMPLIANCE);
        uint256 balance = token.balanceOf(address(carol));
        vm.prank(compliance);
        holds.place(address(carol), balance, Roles.COMPLIANCE, "suspicious activity");

        BranchApprovals.CardAuthorisation memory card = _card(WITHDRAWAL, 0);
        vm.prank(atm1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, address(carol), WITHDRAWAL, 0));
        cash.withdrawAtAtm(1, card);
    }

    function test_Atm_RefusedBeyondWhatTheMachineHolds() public {
        BranchApprovals.CardAuthorisation memory card = _card(WITHDRAWAL, 0);
        bytes32 empty = _id(_atm(1, atm2));
        vm.prank(atm2);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.InsufficientCash.selector, empty, 0, WITHDRAWAL));
        cash.withdrawAtAtm(1, card);
    }

    function test_Atm_OnlyTheMachineThatTookItReports() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        vm.prank(atm2);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NotItsAtm.selector, ref, atm2));
        cash.confirmDispense(ref);
    }

    function test_Atm_ReportedOnlyOnce() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        vm.startPrank(atm1);
        cash.confirmDispense(ref);
        vm.expectRevert(
            abi.encodeWithSelector(CashOperations.NotHeld.selector, ref, CashOperations.WithdrawalStatus.Dispensed)
        );
        cash.reportFailure(ref);
        vm.stopPrank();
    }

    function test_Atm_FlaggedAfterTheDispenseTimeout() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        assertFalse(cash.isFlagged(ref));
        vm.warp(block.timestamp + DISPENSE_TIMEOUT + 1);
        assertTrue(cash.isFlagged(ref));
        vm.prank(atm1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.DispenseTimedOut.selector, ref));
        cash.confirmDispense(ref);
    }

    // Counts

    /// @dev The ATM fails to dispense, second run: the machine reports nothing, the amount stays pending
    /// and flagged, and the next count finds the cash still in the machine and returns it.
    function test_Count_ReturnsAFlaggedWithdrawalTheMachineStillHolds() public {
        uint256 before = token.balanceOf(address(carol));
        bytes32 ref = _withdraw(WITHDRAWAL);
        vm.warp(block.timestamp + DISPENSE_TIMEOUT + 1);

        _approved(_proposeCount(_atm(1, atm1), 200_000 * HKD));

        assertEq(uint8(cash.withdrawal(ref).status), uint8(CashOperations.WithdrawalStatus.Returned));
        assertEq(token.balanceOf(address(carol)), before, "the customer is whole");
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 200_000 * HKD, "ATM cash unchanged");
        assertTrue(cash.lastCount(_id(_atm(1, atm1))).matched);
        _assertBooksBalance();
    }

    function test_Count_DispensesAFlaggedWithdrawalTheShortfallCovers() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        vm.warp(block.timestamp + DISPENSE_TIMEOUT + 1);
        uint256 supply = token.totalSupply();

        _approved(_proposeCount(_atm(1, atm1), 200_000 * HKD - WITHDRAWAL));

        assertEq(uint8(cash.withdrawal(ref).status), uint8(CashOperations.WithdrawalStatus.Dispensed));
        assertEq(token.totalSupply(), supply - WITHDRAWAL);
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 200_000 * HKD - WITHDRAWAL);
        assertTrue(cash.lastCount(_id(_atm(1, atm1))).matched);
        _assertBooksBalance();
    }

    function test_Count_SettlesFlaggedWithdrawalsInOrder() public {
        bytes32 first = _withdraw(1_000 * HKD);
        bytes32 second = _withdrawWith(_card(2_000 * HKD, bytes32(uint256(1))));
        vm.warp(block.timestamp + DISPENSE_TIMEOUT + 1);

        // The machine is 1,000 short: the first was dispensed and the second was not.
        _approved(_proposeCount(_atm(1, atm1), 199_000 * HKD));

        assertEq(uint8(cash.withdrawal(first).status), uint8(CashOperations.WithdrawalStatus.Dispensed));
        assertEq(uint8(cash.withdrawal(second).status), uint8(CashOperations.WithdrawalStatus.Returned));
        assertTrue(cash.lastCount(_id(_atm(1, atm1))).matched);
    }

    function test_Count_RefusedWhileADispenseIsInProgress() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        uint256 id = _proposeCount(_atm(1, atm1), 200_000 * HKD - WITHDRAWAL);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.DispenseInProgress.selector, ref));
        cash.confirmOrder(id);
        vm.prank(atm1);
        cash.confirmDispense(ref);
        _approved(id);
        assertTrue(cash.lastCount(_id(_atm(1, atm1))).matched);
    }

    function test_Count_LeavesABlockedCustomersWithdrawalForTheNextCount() public {
        bytes32 ref = _withdraw(WITHDRAWAL);
        vm.warp(block.timestamp + DISPENSE_TIMEOUT + 1);
        address compliance = _staff("compliance");
        _grantStaff(compliance, Roles.COMPLIANCE);
        vm.prank(compliance);
        token.blockUser(address(carol));

        _approved(_proposeCount(_atm(1, atm1), 200_000 * HKD));
        assertEq(uint8(cash.withdrawal(ref).status), uint8(CashOperations.WithdrawalStatus.Held));

        vm.prank(governance);
        token.unblockUser(address(carol));
        _approved(_proposeCount(_atm(1, atm1), 200_000 * HKD));
        assertEq(uint8(cash.withdrawal(ref).status), uint8(CashOperations.WithdrawalStatus.Returned));
    }

    /// @dev Ledger mismatch on cash: the count differs, the figure is marked and nothing is posted.
    function test_Count_DifferenceMarksTheFigureAndPostsNothing() public {
        uint256 entries = ledger.entryCount();
        _approved(_proposeCount(_vault(1), 249_000 * HKD));

        CashOperations.CountResult memory c = cash.lastCount(_id(_vault(1)));
        assertFalse(c.matched);
        assertEq(c.counted, 249_000 * HKD);
        assertEq(c.book, 250_000 * HKD);
        assertEq(ledger.entryCount(), entries);
        assertEq(cash.cashAt(_id(_vault(1))), 250_000 * HKD, "the books are not changed to fit");
    }

    // Under dual control

    function test_Move_BetweenPlacesOfTheBranch() public {
        _approved(_proposeMove(_vault(1), _atm(1, atm1), 50_000 * HKD));
        assertEq(cash.cashAt(_id(_vault(1))), 200_000 * HKD);
        assertEq(cash.cashAt(_id(_atm(1, atm1))), 250_000 * HKD);
        assertEq(_split(), _ledgerCash());
    }

    function test_Move_LeavesWhatIsOnItsWayOut() public {
        _withdraw(WITHDRAWAL);
        uint256 id = _proposeMove(_atm(1, atm1), _vault(1), 200_000 * HKD);
        bytes32 atm = _id(_atm(1, atm1));
        vm.prank(supervisor1);
        vm.expectRevert(
            abi.encodeWithSelector(CashOperations.InsufficientCash.selector, atm, 200_000 * HKD - WITHDRAWAL, 200_000 * HKD)
        );
        cash.confirmOrder(id);
    }

    function test_Move_NotBetweenBranches() public {
        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.OtherBranch.selector, 1, 2));
        cash.proposeMove(_vault(1), _vault(2), HKD);
    }

    function test_Bank_SurplusCashToTheSettlementAccount() public {
        int256 settlement = ledger.balanceOf(GeneralLedger.Account.Settlement);
        _approved(_proposeBanking(100_000 * HKD));
        assertEq(cash.cashAt(_id(_vault(1))), 150_000 * HKD);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Settlement), settlement + int256(100_000 * HKD));
        assertEq(_split(), _ledgerCash());
        _assertBooksBalance();
    }

    function test_DualControl_OnlyTheBranchsCustodianProposes() public {
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NotCustodian.selector, supervisor1, 1));
        cash.proposeBanking(1, HKD);
    }

    function test_DualControl_OnlyASupervisorOfTheBranchApproves() public {
        uint256 id = _proposeBanking(HKD);
        vm.prank(supervisor2);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NotSupervisor.selector, supervisor2, 1));
        cash.confirmOrder(id);
        vm.prank(teller1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NotSupervisor.selector, teller1, 1));
        cash.confirmOrder(id);
    }

    function test_DualControl_MakerCannotApprove() public {
        vm.prank(address(staffRoles));
        manager.grantRole(SUPERVISOR_1, custodian, 0);
        uint256 id = _proposeBanking(HKD);
        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.ApproverIsMaker.selector, custodian));
        cash.confirmOrder(id);
    }

    function test_DualControl_RefusedIfTheMakerLostTheRole() public {
        uint256 id = _proposeBanking(HKD);
        vm.prank(address(staffRoles));
        manager.revokeRole(CUSTODIAN_1, custodian);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NotCustodian.selector, custodian, 1));
        cash.confirmOrder(id);
    }

    function test_DualControl_ApprovedOnce() public {
        uint256 id = _proposeBanking(HKD);
        _approved(id);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NoSuchOrder.selector, id));
        cash.confirmOrder(id);
    }

    function test_DualControl_MakerCancels() public {
        uint256 id = _proposeBanking(HKD);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NotMaker.selector, supervisor1, id));
        cash.cancelOrder(id);
        vm.prank(custodian);
        cash.cancelOrder(id);
        vm.prank(supervisor1);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.NoSuchOrder.selector, id));
        cash.confirmOrder(id);
    }

    function test_Location_VaultHasNoHolderAndOthersDo() public {
        CashOperations.Location memory bad = CashOperations.Location(CashOperations.Place.Drawer, 1, address(0));
        vm.prank(custodian);
        vm.expectRevert(abi.encodeWithSelector(CashOperations.InvalidLocation.selector, bad));
        cash.proposeCount(bad, 0);
    }

    // Helpers, public for the handler

    function deposit(address customer, uint256 amount) public {
        _deposit(customer, amount);
    }

    function withdraw(uint256 amount, bytes32 nonce) public returns (bytes32) {
        return _withdrawWith(_card(amount, nonce));
    }

    function proposeAndApproveCount(CashOperations.Location memory at, uint256 counted) public {
        _approved(_proposeCount(at, counted));
    }

    function proposeAndApproveMove(CashOperations.Location memory from, CashOperations.Location memory to, uint256 amount) public {
        _approved(_proposeMove(from, to, amount));
    }

    function proposeAndApproveBanking(uint256 amount) public {
        _approved(_proposeBanking(amount));
    }

    function _deposit(address customer, uint256 amount) private {
        vm.prank(teller1);
        cash.deposit(1, customer, amount);
    }

    function _withdraw(uint256 amount) private returns (bytes32) {
        return _withdrawWith(_card(amount, 0));
    }

    function _withdrawWith(BranchApprovals.CardAuthorisation memory card) private returns (bytes32) {
        vm.prank(atm1);
        return cash.withdrawAtAtm(1, card);
    }

    function _proposeMove(
        CashOperations.Location memory from,
        CashOperations.Location memory to,
        uint256 amount
    ) private returns (uint256) {
        vm.prank(custodian);
        return cash.proposeMove(from, to, amount);
    }

    function _proposeBanking(uint256 amount) private returns (uint256) {
        vm.prank(custodian);
        return cash.proposeBanking(1, amount);
    }

    function _proposeCount(CashOperations.Location memory at, uint256 counted) private returns (uint256) {
        vm.prank(custodian);
        return cash.proposeCount(at, counted);
    }

    function _approved(uint256 id) private {
        vm.prank(supervisor1);
        cash.confirmOrder(id);
    }

    function _id(CashOperations.Location memory l) private view returns (bytes32) {
        return cash.locationId(l);
    }

    function _split() private view returns (int256) {
        return int256(cash.cashAt(_id(_vault(1))) + cash.cashAt(_id(_drawer(1, teller1))) + cash.cashAt(_id(_atm(1, atm1))));
    }

    function _ledgerCash() private view returns (int256) {
        return ledger.balanceOf(GeneralLedger.Account.Cash);
    }

    /// @dev The start of the next day in UTC, after the fixture's governance delays.
    function _nextUtcDay() private view returns (uint256) {
        return (block.timestamp / 1 days + 1) * 1 days;
    }

    function _countLogs(bytes32 topic) private returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) if (logs[i].topics[0] == topic) ++n;
    }

    // The card

    /// @dev Carol's card authorises a withdrawal of `amount` at ATM 1, under the one-use number `seq`
    /// for that intent.
    function _card(uint256 amount, bytes32 seq) private view returns (BranchApprovals.CardAuthorisation memory a) {
        uint192 key = cash.intentKey(cash.ATM_WITHDRAWAL(), 1, atm1);
        a = _cardAuthorisation(cardKey, address(carol), address(cash), key, amount);
        a.nonce = bytes32((uint256(key) << 64) | uint256(seq));
        a.signature = _cardSignature(cardKey, address(carol), address(cash), amount, a.nonce);
    }


}

/// @dev Drives the cash module through random runs of the daily cash work for the invariant test.
contract CashHandler is Test {
    CashOperationsTest immutable bank;
    CashOperations immutable cash;
    address immutable carol;
    address immutable atm;
    bytes32 immutable vaultId;
    bytes32 immutable drawerId;
    bytes32 immutable atmId;
    CashOperations.Location vault;
    CashOperations.Location drawer;
    CashOperations.Location atmAt;
    bytes32[] refs;
    uint256 nonce;

    constructor(
        CashOperationsTest bank_,
        CashOperations cash_,
        address carol_,
        address atm_,
        CashOperations.Location memory vault_,
        CashOperations.Location memory drawer_,
        CashOperations.Location memory atmAt_
    ) {
        (bank, cash, carol, atm) = (bank_, cash_, carol_, atm_);
        (vault, drawer, atmAt) = (vault_, drawer_, atmAt_);
        (vaultId, drawerId, atmId) = (cash_.locationId(vault_), cash_.locationId(drawer_), cash_.locationId(atmAt_));
    }

    function deposit(uint256 amount) external {
        (uint256 drawerLimit, , , ) = cash.limits();
        uint256 room = drawerLimit - cash.cashAt(drawerId);
        if (room == 0) return;
        bank.deposit(carol, bound(amount, 1, room));
    }

    function withdraw(uint256 amount) external {
        uint256 free = cash.cashAt(atmId) - cash.inFlight(atmId);
        uint256 most = Math.min(Math.min(free, cash.atmAvailable(carol)), cash.token().balanceOf(carol));
        if (most == 0) return;
        refs.push(bank.withdraw(bound(amount, 1, most), bytes32(nonce++)));
    }

    function confirm(uint256 i) external {
        (bytes32 ref, bool ok) = _held(i);
        if (!ok || cash.isFlagged(ref)) return;
        vm.prank(atm);
        cash.confirmDispense(ref);
    }

    function fail(uint256 i) external {
        (bytes32 ref, bool ok) = _held(i);
        if (!ok || cash.isFlagged(ref)) return;
        vm.prank(atm);
        cash.reportFailure(ref);
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 1 days));
    }

    /// @dev Counts the ATM as short by `short`, which settles flagged withdrawals against it, once no
    /// dispense is still within its timeout.
    function countAtm(uint256 short) external {
        for (uint256 i = 0; i < refs.length; ++i) {
            if (cash.withdrawal(refs[i]).status == CashOperations.WithdrawalStatus.Held && !cash.isFlagged(refs[i])) return;
        }
        uint256 book = cash.cashAt(atmId);
        bank.proposeAndApproveCount(atmAt, book - bound(short, 0, book));
    }

    function moveToVault(uint256 amount) external {
        uint256 inDrawer = cash.cashAt(drawerId);
        if (inDrawer == 0) return;
        bank.proposeAndApproveMove(drawer, vault, bound(amount, 1, inDrawer));
    }

    function bankSurplus(uint256 amount) external {
        uint256 inVault = cash.cashAt(vaultId);
        if (inVault == 0) return;
        bank.proposeAndApproveBanking(bound(amount, 1, inVault));
    }

    function _held(uint256 i) private view returns (bytes32 ref, bool ok) {
        if (refs.length == 0) return (0, false);
        ref = refs[bound(i, 0, refs.length - 1)];
        ok = cash.withdrawal(ref).status == CashOperations.WithdrawalStatus.Held;
    }
}
