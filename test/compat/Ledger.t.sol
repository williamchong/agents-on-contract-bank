// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {SpikeDepositToken} from "../../contracts/spike/SpikeDepositToken.sol";
import {
    SpikeLedger,
    SpikeLedgerEvents,
    SpikeLedgerHashed,
    SpikeLedgerStored
} from "../../contracts/spike/SpikeLedger.sol";

function _lines(SpikeLedger.Account a, int128 x) pure returns (SpikeLedger.Line[] memory lines) {
    lines = new SpikeLedger.Line[](1);
    lines[0] = SpikeLedger.Line(a, x);
}

function _lines(
    SpikeLedger.Account a,
    int128 x,
    SpikeLedger.Account b,
    int128 y
) pure returns (SpikeLedger.Line[] memory lines) {
    lines = new SpikeLedger.Line[](2);
    lines[0] = SpikeLedger.Line(a, x);
    lines[1] = SpikeLedger.Line(b, y);
}

/// @dev Checks that the ledger keeps the books balanced with the deposit token through each kind
/// of entry, under each of the three ways of keeping entries. Run with --gas-stats to compare
/// their cost. See open question 8 in docs/plan.md.
abstract contract LedgerTest is Test {
    uint64 constant LEDGER = 1;
    uint64 constant BOOKKEEPER = 2;

    AccessManager manager;
    SpikeDepositToken token;
    SpikeLedger ledger;

    address customer = makeAddr("customer");
    address pending = makeAddr("pending");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        manager = new AccessManager(address(this));
        token = new SpikeDepositToken(address(manager));
        ledger = _deploy();

        bytes4[] memory tokenSelectors = new bytes4[](2);
        tokenSelectors[0] = token.mint.selector;
        tokenSelectors[1] = token.burn.selector;
        manager.setTargetFunctionRole(address(token), tokenSelectors, LEDGER);
        manager.grantRole(LEDGER, address(ledger), 0);

        bytes4[] memory ledgerSelectors = new bytes4[](3);
        ledgerSelectors[0] = ledger.post.selector;
        ledgerSelectors[1] = ledger.postWithMint.selector;
        ledgerSelectors[2] = ledger.postWithBurn.selector;
        manager.setTargetFunctionRole(address(ledger), ledgerSelectors, BOOKKEEPER);
        manager.grantRole(BOOKKEEPER, address(this), 0);

        token.allowUser(customer);
        token.allowUser(pending);
        token.allowUser(bob);

        ledger.post(_lines(SpikeLedger.Account.Settlement, 1000, SpikeLedger.Account.Equity, -1000), "capital");
    }

    function _deploy() internal virtual returns (SpikeLedger);

    // Tokens created

    function test_CashPaidIn() public {
        _cashIn(100);
        assertEq(token.balanceOf(customer), 100);
        assertEq(ledger.balanceOf(SpikeLedger.Account.Cash), 100);
        _assertBooksBalance();
    }

    function test_PaymentReceived() public {
        ledger.postWithMint(customer, 50, _lines(SpikeLedger.Account.Settlement, 50), "payment in");
        assertEq(ledger.balanceOf(SpikeLedger.Account.Settlement), 1050);
        _assertBooksBalance();
    }

    function test_LoanDrawnDown() public {
        ledger.postWithMint(customer, 500, _lines(SpikeLedger.Account.Loans, 500), "drawdown");
        assertEq(ledger.balanceOf(SpikeLedger.Account.Loans), 500);
        _assertBooksBalance();
    }

    function test_InterestPaid() public {
        ledger.postWithMint(customer, 2, _lines(SpikeLedger.Account.Equity, 2), "interest");
        assertEq(ledger.balanceOf(SpikeLedger.Account.Equity), -998);
        _assertBooksBalance();
    }

    // Tokens destroyed

    function test_CashPaidOut() public {
        _cashIn(100);
        vm.prank(customer);
        token.transfer(pending, 30);
        ledger.postWithBurn(pending, 30, _lines(SpikeLedger.Account.Cash, -30), "cash out");

        assertEq(token.balanceOf(customer), 70);
        assertEq(ledger.balanceOf(SpikeLedger.Account.Cash), 70);
        _assertBooksBalance();
    }

    function test_PaymentSent() public {
        _cashIn(100);
        vm.prank(customer);
        token.transfer(pending, 40);
        ledger.postWithBurn(pending, 40, _lines(SpikeLedger.Account.Settlement, -40), "payment out");

        assertEq(ledger.balanceOf(SpikeLedger.Account.Settlement), 960);
        _assertBooksBalance();
    }

    function test_FeeCharged() public {
        _cashIn(100);
        ledger.postWithBurn(customer, 5, _lines(SpikeLedger.Account.Equity, -5), "fee");
        assertEq(ledger.balanceOf(SpikeLedger.Account.Equity), -1005);
        _assertBooksBalance();
    }

    // No tokens moved

    function test_AllowanceRaised() public {
        ledger.post(_lines(SpikeLedger.Account.Equity, 10, SpikeLedger.Account.Allowance, -10), "allowance");
        assertEq(ledger.balanceOf(SpikeLedger.Account.Allowance), -10);
        _assertBooksBalance();
    }

    function test_TransferBetweenCustomers_PostsNothing() public {
        _cashIn(100);
        uint256 entries = ledger.entryCount();
        vm.prank(customer);
        token.transfer(bob, 25);
        assertEq(ledger.entryCount(), entries);
        _assertBooksBalance();
    }

    // Refusals

    function test_UnbalancedEntryRefused() public {
        vm.expectRevert(abi.encodeWithSelector(SpikeLedger.UnbalancedEntry.selector, int256(10)));
        ledger.post(_lines(SpikeLedger.Account.Cash, 10), "unbalanced");
    }

    function test_UnbalancedMintCreatesNothing() public {
        vm.expectRevert(abi.encodeWithSelector(SpikeLedger.UnbalancedEntry.selector, int256(-1)));
        ledger.postWithMint(customer, 100, _lines(SpikeLedger.Account.Cash, 99), "short");
        assertEq(token.totalSupply(), 0);
    }

    function test_DepositsLineRefused() public {
        vm.expectRevert(SpikeLedger.DepositsMoveOnlyWithTokens.selector);
        ledger.post(_lines(SpikeLedger.Account.Cash, 10, SpikeLedger.Account.Deposits, -10), "no tokens");
    }

    function test_MintAndBurnOnlyByLedger() public {
        _cashIn(100);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        token.mint(customer, 100);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        token.burn(customer, 100);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        token.mint(bob, 100);
    }

    function test_PostOnlyByBookkeeper() public {
        SpikeLedger.Line[] memory lines = _lines(SpikeLedger.Account.Cash, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        ledger.postWithMint(bob, 100, lines, "self-paid");

        _cashIn(100);
        lines = _lines(SpikeLedger.Account.Cash, -100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        ledger.postWithBurn(customer, 100, lines, "unpaid");
    }

    // Helpers

    function _cashIn(uint256 amount) internal returns (uint256) {
        return ledger.postWithMint(customer, amount, _lines(SpikeLedger.Account.Cash, int128(int256(amount))), "cash in");
    }

    function _assertBooksBalance() internal view {
        int256 sum;
        for (uint8 i = 0; i <= uint8(type(SpikeLedger.Account).max); ++i) sum += ledger.balanceOf(SpikeLedger.Account(i));
        assertEq(sum, 0, "assets equal liabilities and equity");
    }
}

contract LedgerEventsTest is LedgerTest {
    LedgerHandler handler;

    function setUp() public override {
        super.setUp();
        handler = new LedgerHandler(ledger, customer, bob);
        manager.grantRole(BOOKKEEPER, address(handler), 0);
        targetContract(address(handler));
    }

    function invariant_BooksBalance() public view {
        _assertBooksBalance();
    }

    function _deploy() internal override returns (SpikeLedger) {
        return new SpikeLedgerEvents(address(manager), token);
    }

    function test_EntryEmittedWithDepositsLine() public {
        SpikeLedger.Line[] memory entry = _lines(SpikeLedger.Account.Cash, 100, SpikeLedger.Account.Deposits, -100);
        vm.expectEmit(address(ledger));
        emit SpikeLedger.EntryPosted(ledger.entryCount() + 1, "cash in", entry);
        _cashIn(100);
    }
}

contract LedgerHashedTest is LedgerTest {
    function _deploy() internal override returns (SpikeLedger) {
        return new SpikeLedgerHashed(address(manager), token);
    }

    function test_EntryProvenByHash() public {
        uint256 id = _cashIn(100);
        SpikeLedgerHashed hashed = SpikeLedgerHashed(address(ledger));

        hashed.checkEntry(id, _lines(SpikeLedger.Account.Cash, 100, SpikeLedger.Account.Deposits, -100));

        vm.expectRevert(abi.encodeWithSelector(SpikeLedgerHashed.EntryMismatch.selector, id));
        hashed.checkEntry(id, _lines(SpikeLedger.Account.Cash, 90, SpikeLedger.Account.Deposits, -90));
    }
}

contract LedgerStoredTest is LedgerTest {
    function _deploy() internal override returns (SpikeLedger) {
        return new SpikeLedgerStored(address(manager), token);
    }

    function test_EntryReadBack() public {
        uint256 id = _cashIn(100);
        SpikeLedger.Line[] memory entry = SpikeLedgerStored(address(ledger)).entry(id);
        assertEq(entry.length, 2);
        assertEq(uint8(entry[1].account), uint8(SpikeLedger.Account.Deposits));
        assertEq(entry[1].amount, -100);
    }
}

/// @dev Random sequences of every kind of posting, customer transfers and attempts to mint
/// around the ledger. Whatever the order, the books balance.
contract LedgerHandler is Test {
    SpikeLedger immutable ledger;
    SpikeDepositToken immutable token;
    address immutable customer;
    address immutable bob;

    constructor(SpikeLedger ledger_, address customer_, address bob_) {
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
    function _other(uint8 seed) private pure returns (SpikeLedger.Account) {
        uint8 i = seed % uint8(type(SpikeLedger.Account).max);
        return SpikeLedger.Account(i >= uint8(SpikeLedger.Account.Deposits) ? i + 1 : i);
    }
}
