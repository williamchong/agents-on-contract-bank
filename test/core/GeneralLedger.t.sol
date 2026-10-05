// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20Restricted} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";
import {BankFixture} from "./BankFixture.sol";

function _lines(GeneralLedger.Account a, int128 x) pure returns (GeneralLedger.Line[] memory lines) {
    lines = new GeneralLedger.Line[](1);
    lines[0] = GeneralLedger.Line(a, x);
}

function _lines(
    GeneralLedger.Account a,
    int128 x,
    GeneralLedger.Account b,
    int128 y
) pure returns (GeneralLedger.Line[] memory lines) {
    lines = new GeneralLedger.Line[](2);
    lines[0] = GeneralLedger.Line(a, x);
    lines[1] = GeneralLedger.Line(b, y);
}

/// @dev Checks that the ledger keeps the books balanced with the deposit token through each kind
/// of entry in the deposit token table of docs/architecture.md, from the opening balance sheet.
contract GeneralLedgerTest is BankFixture {
    LedgerHandler handler;

    function setUp() public override {
        super.setUp();
        manager.grantRole(Roles.BOOKKEEPER, address(this), 0);

        handler = new LedgerHandler(ledger, alice, bob);
        manager.grantRole(Roles.BOOKKEEPER, address(handler), 0);
        targetContract(address(handler));
    }

    function invariant_BooksBalance() public view {
        _assertBooksBalance();
    }

    // Opening balance sheet

    function test_Opening_MatchesTheScenarios() public view {
        assertEq(ledger.balanceOf(GeneralLedger.Account.Settlement), _hkd(1_000_000));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Cash), _hkd(500_000));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Securities), _hkd(2_500_000));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Loans), _hkd(9_300_000));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Allowance), -_hkd(93_000));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Deposits), -_hkd(12_300_000));
        assertEq(ledger.balanceOf(GeneralLedger.Account.Equity), -_hkd(907_000));
        assertEq(token.balanceOf(alice), 100_000 * HKD);
        assertEq(ledger.entryCount(), 1);
        _assertBooksBalance();
    }

    function test_Opening_OnlyOnce() public {
        vm.expectRevert(GeneralLedger.OpeningNotFirst.selector);
        ledger.postOpening(new address[](0), new uint256[](0), new GeneralLedger.Line[](0), "again");
    }

    function test_Opening_UnbalancedCreatesNothing() public {
        GeneralLedger fresh = _freshLedger();
        address[] memory holders = new address[](1);
        holders[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.expectRevert(abi.encodeWithSelector(GeneralLedger.UnbalancedEntry.selector, int256(-1)));
        fresh.postOpening(holders, amounts, _lines(GeneralLedger.Account.Cash, 99), "short");
        assertEq(fresh.entryCount(), 0);
    }

    function test_Opening_RefusesHolderNotAdmitted() public {
        GeneralLedger fresh = _freshLedger();
        address[] memory holders = new address[](1);
        holders[0] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.expectRevert(abi.encodeWithSelector(ERC20Restricted.ERC20UserRestricted.selector, bob));
        fresh.postOpening(holders, amounts, _lines(GeneralLedger.Account.Cash, 100), "not admitted");
    }

    function test_Opening_HoldersMatchAmounts() public {
        GeneralLedger fresh = _freshLedger();
        vm.expectRevert(abi.encodeWithSelector(GeneralLedger.HoldersMismatch.selector, 1, 0));
        fresh.postOpening(new address[](1), new uint256[](0), new GeneralLedger.Line[](0), "mismatch");
    }

    // Tokens created

    function test_CashPaidIn() public {
        _cashIn(100);
        assertEq(token.balanceOf(alice), 100_000 * HKD + 100);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Cash), _hkd(500_000) + 100);
        _assertBooksBalance();
    }

    function test_PaymentReceived() public {
        ledger.postWithMint(alice, 50, _lines(GeneralLedger.Account.Settlement, 50), "payment in");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Settlement), _hkd(1_000_000) + 50);
        _assertBooksBalance();
    }

    function test_LoanDrawnDown() public {
        ledger.postWithMint(alice, 500, _lines(GeneralLedger.Account.Loans, 500), "drawdown");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Loans), _hkd(9_300_000) + 500);
        _assertBooksBalance();
    }

    function test_InterestPaid() public {
        ledger.postWithMint(alice, 2, _lines(GeneralLedger.Account.Equity, 2), "interest");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Equity), -_hkd(907_000) + 2);
        _assertBooksBalance();
    }

    // Tokens destroyed

    function test_CashPaidOut() public {
        vm.prank(alice);
        token.transfer(pending, 30);
        ledger.postWithBurn(pending, 30, _lines(GeneralLedger.Account.Cash, -30), "cash out");

        assertEq(token.balanceOf(alice), 100_000 * HKD - 30);
        assertEq(ledger.balanceOf(GeneralLedger.Account.Cash), _hkd(500_000) - 30);
        _assertBooksBalance();
    }

    function test_PaymentSent() public {
        vm.prank(alice);
        token.transfer(pending, 40);
        ledger.postWithBurn(pending, 40, _lines(GeneralLedger.Account.Settlement, -40), "payment out");

        assertEq(ledger.balanceOf(GeneralLedger.Account.Settlement), _hkd(1_000_000) - 40);
        _assertBooksBalance();
    }

    function test_FeeCharged() public {
        ledger.postWithBurn(alice, 5, _lines(GeneralLedger.Account.Equity, -5), "fee");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Equity), -_hkd(907_000) - 5);
        _assertBooksBalance();
    }

    // No tokens moved

    function test_AllowanceRaised() public {
        ledger.post(_lines(GeneralLedger.Account.Equity, 10, GeneralLedger.Account.Allowance, -10), "allowance");
        assertEq(ledger.balanceOf(GeneralLedger.Account.Allowance), -_hkd(93_000) - 10);
        _assertBooksBalance();
    }

    function test_TransferBetweenCustomers_PostsNothing() public {
        uint256 entries = ledger.entryCount();
        vm.prank(alice);
        token.transfer(bob, 25);
        assertEq(ledger.entryCount(), entries);
        _assertBooksBalance();
    }

    // The entry as the indexer sees it

    function test_EntryEmittedWithDepositsLineAndPoster() public {
        GeneralLedger.Line[] memory entry = _lines(
            GeneralLedger.Account.Cash,
            100,
            GeneralLedger.Account.Deposits,
            -100
        );
        vm.expectEmit(address(ledger));
        emit GeneralLedger.EntryPosted(ledger.entryCount() + 1, "cash in", address(this), entry);
        _cashIn(100);
    }

    // Refusals

    function test_UnbalancedEntryRefused() public {
        vm.expectRevert(abi.encodeWithSelector(GeneralLedger.UnbalancedEntry.selector, int256(10)));
        ledger.post(_lines(GeneralLedger.Account.Cash, 10), "unbalanced");
    }

    function test_UnbalancedMintCreatesNothing() public {
        uint256 supply = token.totalSupply();
        vm.expectRevert(abi.encodeWithSelector(GeneralLedger.UnbalancedEntry.selector, int256(-1)));
        ledger.postWithMint(alice, 100, _lines(GeneralLedger.Account.Cash, 99), "short");
        assertEq(token.totalSupply(), supply);
    }

    function test_DepositsLineRefused() public {
        vm.expectRevert(GeneralLedger.DepositsMoveOnlyWithTokens.selector);
        ledger.post(_lines(GeneralLedger.Account.Cash, 10, GeneralLedger.Account.Deposits, -10), "no tokens");
    }

    // Helpers

    function _cashIn(uint256 amount) internal returns (uint256) {
        return ledger.postWithMint(alice, amount, _lines(GeneralLedger.Account.Cash, int128(int256(amount))), "cash in");
    }

    /// @dev A ledger not yet opened, on a token of its own, wired as the fixture wires the bank's.
    function _freshLedger() private returns (GeneralLedger fresh) {
        DepositToken freshToken = new DepositToken(address(manager));
        fresh = new GeneralLedger(address(manager), freshToken);
        _wire(address(freshToken), freshToken.mint.selector, Roles.LEDGER);
        manager.grantRole(Roles.LEDGER, address(fresh), 0);
        freshToken.allowUser(alice);
    }
}

/// @dev Random sequences of every kind of posting, customer transfers and attempts to mint
/// around the ledger. Whatever the order, the books balance.
contract LedgerHandler is Test {
    GeneralLedger immutable ledger;
    DepositToken immutable token;
    address immutable customer;
    address immutable bob;

    constructor(GeneralLedger ledger_, address customer_, address bob_) {
        ledger = ledger_;
        token = ledger_.token();
        customer = customer_;
        bob = bob_;
    }

    function mint(uint8 account, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        ledger.postWithMint(customer, amount, _lines(_other(account), int128(int256(amount))), "");
    }

    function burn(uint8 account, uint256 amount) external {
        uint256 held = token.balanceOf(customer);
        if (held == 0) return;
        amount = bound(amount, 1, held);
        ledger.postWithBurn(customer, amount, _lines(_other(account), -int128(int256(amount))), "");
    }

    function reclassify(uint8 from, uint8 to, uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        int128 x = int128(int256(amount));
        ledger.post(_lines(_other(from), x, _other(to), -x), "");
    }

    function transfer(uint256 amount) external {
        amount = bound(amount, 0, token.balanceOf(customer));
        vm.prank(customer);
        token.transfer(bob, amount);
    }

    function mintAround(uint256 amount) external {
        try token.mint(customer, amount) {} catch {}
    }

    /// @dev Any account but Deposits, which moves only with tokens.
    function _other(uint8 seed) private pure returns (GeneralLedger.Account) {
        uint8 i = seed % uint8(type(GeneralLedger.Account).max);
        return GeneralLedger.Account(i >= uint8(GeneralLedger.Account.Deposits) ? i + 1 : i);
    }
}
