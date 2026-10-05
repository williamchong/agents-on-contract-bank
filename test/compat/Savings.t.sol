// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {ERC20Restricted} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";
import {IERC7943Fungible} from "@openzeppelin/community-contracts/contracts/interfaces/IERC7943.sol";
import {SpikeDepositToken} from "../../contracts/spike/SpikeDepositToken.sol";
import {SpikeLedger, SpikeLedgerEvents} from "../../contracts/spike/SpikeLedger.sol";
import {SpikeSavings} from "../../contracts/spike/SpikeSavings.sol";

/// @dev The deposit token with a way to block a customer, which the spike token does not expose.
contract BlockableDepositToken is SpikeDepositToken {
    constructor(address manager) SpikeDepositToken(manager) {}

    function blockUser(address account) external {
        _blockUser(account);
    }
}

/// @dev Checks that freezes and forced transfers reach money a customer has moved into the savings
/// account, that interest paid in through the ledger keeps the books balanced, and that the vault
/// always holds what its shares are worth. See open question 6 in docs/plan.md.
contract SavingsTest is Test {
    uint64 constant LEDGER = 1;
    uint64 constant BOOKKEEPER = 2;
    uint64 constant ENFORCER = 3;

    AccessManager manager;
    BlockableDepositToken token;
    SpikeLedgerEvents ledger;
    SpikeSavings savings;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address pending = makeAddr("pending");
    address enforcer = makeAddr("enforcer");

    function setUp() public {
        manager = new AccessManager(address(this));
        token = new BlockableDepositToken(address(manager));
        ledger = new SpikeLedgerEvents(address(manager), token);
        savings = new SpikeSavings(address(manager), token);

        _setRole(address(token), token.mint.selector, LEDGER);
        _setRole(address(token), token.burn.selector, LEDGER);
        _setRole(address(ledger), ledger.postWithMint.selector, BOOKKEEPER);
        _setRole(address(token), token.setFrozenTokens.selector, ENFORCER);
        _setRole(address(savings), savings.setFrozenTokens.selector, ENFORCER);
        _setRole(address(savings), savings.forcedTransfer.selector, ENFORCER);
        manager.grantRole(LEDGER, address(ledger), 0);
        manager.grantRole(BOOKKEEPER, address(this), 0);
        manager.grantRole(ENFORCER, enforcer, 0);

        token.allowUser(address(savings));
        token.allowUser(alice);
        token.allowUser(bob);
        token.allowUser(pending);

        _cashIn(alice, 1000);
        _cashIn(bob, 1000);
    }

    // Paying in, interest and withdrawing

    function test_PayInAndWithdraw() public {
        uint256 shares = _payIn(alice, 400);
        assertEq(savings.balanceOf(alice), shares);
        assertEq(token.balanceOf(address(savings)), 400);

        vm.prank(alice);
        savings.withdraw(400, alice, alice);
        assertEq(token.balanceOf(alice), 1000);
        assertEq(savings.balanceOf(alice), 0);
        _assertBooksBalance();
    }

    function test_Interest_RaisesShareValueAndBooksBalance() public {
        uint256 shares = _payIn(alice, 400);
        _payInterest(40);

        assertGe(savings.previewRedeem(shares), 439);
        assertEq(-ledger.balanceOf(SpikeLedger.Account.Deposits), int256(token.totalSupply()));
        _assertBooksBalance();

        vm.prank(alice);
        savings.redeem(shares, alice, alice);
        assertGe(token.balanceOf(alice), 1039);
        _assertBooksBalance();
    }

    // Holds

    function test_Freeze_BlocksWithdrawingHeldShares() public {
        _payIn(alice, 400);
        _hold(alice, 300);

        uint256 all = savings.balanceOf(alice);
        uint256 free = savings.maxRedeem(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, all, free));
        savings.redeem(all, alice, alice);

        assertEq(savings.maxWithdraw(alice), 100);
        vm.prank(alice);
        savings.withdraw(100, alice, alice);
    }

    /// @dev The frozen shares are counted when the hold is set, so as interest raises their value
    /// they cover more than the hold, never less.
    function test_Freeze_CoverGrowsWithInterest() public {
        _payIn(alice, 400);
        _hold(alice, 300);
        _payInterest(40);

        assertGe(savings.previewRedeem(savings.getFrozenTokens(alice)), 300);
        uint256 free = savings.maxWithdraw(alice);
        vm.prank(alice);
        savings.withdraw(free, alice, alice);
        assertGe(savings.previewRedeem(savings.balanceOf(alice)), 300);
    }

    function test_Freeze_OnDepositsBlocksPayingInHeldMoney() public {
        vm.prank(enforcer);
        token.setFrozenTokens(alice, 800);

        vm.startPrank(alice);
        token.approve(address(savings), 300);
        vm.expectRevert(abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, alice, 300, 200));
        savings.deposit(300, alice);

        savings.deposit(200, alice);
        vm.stopPrank();
    }

    function test_Seize_ForcedTransferThenRedeem() public {
        uint256 shares = _payIn(alice, 400);
        vm.prank(enforcer);
        savings.setFrozenTokens(alice, shares);

        uint256 seized = savings.previewWithdraw(250);
        vm.prank(enforcer);
        savings.forcedTransfer(alice, pending, seized);
        assertEq(savings.getFrozenTokens(alice), shares - seized);

        assertEq(savings.maxRedeem(alice), 0);

        vm.prank(pending);
        savings.redeem(seized, pending, pending);
        assertGe(token.balanceOf(pending), 250);
        _assertBooksBalance();
    }

    function test_ForcedTransfer_FromNothingRefused() public {
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        savings.forcedTransfer(address(0), alice, 1);
    }

    function test_FreezeAndForce_OnlyEnforcer() public {
        _payIn(alice, 400);

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        savings.setFrozenTokens(alice, 1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        savings.forcedTransfer(alice, bob, 1);
        vm.stopPrank();
    }

    // Who may hold shares

    function test_Shares_NotTransferableBetweenHolders() public {
        _payIn(alice, 400);
        vm.prank(alice);
        vm.expectRevert(SpikeSavings.SharesNotTransferable.selector);
        savings.transfer(bob, 1);
    }

    function test_Admission_FollowsDepositAllowList() public {
        vm.startPrank(alice);
        token.approve(address(savings), 100);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, carol, 100, 0));
        savings.deposit(100, carol);
        vm.stopPrank();

        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, carol));
        savings.forcedTransfer(alice, carol, 0);

        token.allowUser(carol);
        vm.prank(alice);
        savings.deposit(100, carol);
        assertGt(savings.balanceOf(carol), 0);
    }

    function test_Blocked_CannotPayInOrWithdraw() public {
        uint256 shares = _payIn(alice, 400);
        token.blockUser(alice);
        assertEq(savings.maxRedeem(alice), 0);
        assertEq(savings.maxWithdraw(alice), 0);
        assertEq(savings.maxDeposit(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxRedeem.selector, alice, shares, 0));
        savings.redeem(shares, alice, alice);

        vm.startPrank(alice);
        token.approve(address(savings), 100);
        vm.expectRevert(abi.encodeWithSelector(ERC20Restricted.ERC20UserRestricted.selector, alice));
        savings.deposit(100, bob);
        vm.stopPrank();
    }

    function test_Vault_CannotHoldItsOwnShares() public {
        vm.startPrank(alice);
        token.approve(address(savings), 100);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, address(savings), 100, 0));
        savings.deposit(100, address(savings));
        vm.stopPrank();
    }

    // Rounding and donations

    /// @dev A first saver pays in one unit and sends the vault a large gift, hoping a later saver's
    /// shares round down to nothing. Without the share offset the later saver would get no shares
    /// and lose all 500; with it they keep their money and the first saver gains nothing.
    function test_Inflation_LaterSaverKeepsTheirMoney() public {
        _payIn(bob, 1);
        vm.prank(bob);
        token.transfer(address(savings), 999);

        _payIn(alice, 500);
        assertGe(savings.maxWithdraw(alice), 499);

        uint256 bobShares = savings.balanceOf(bob);
        vm.prank(bob);
        savings.redeem(bobShares, bob, bob);
        assertLe(token.balanceOf(bob), 1000);
        _assertBooksBalance();
    }

    /// @dev Over any run of paying in, interest, holds and withdrawing, the vault holds at least
    /// what all its shares are worth, and the books balance.
    function testFuzz_VaultCoversSharesAndBooksBalance(uint8[12] calldata ops, uint16[12] calldata amounts) public {
        for (uint256 i = 0; i < ops.length; ++i) {
            address who = ops[i] % 2 == 0 ? alice : bob;
            uint256 op = (ops[i] / 2) % 4;
            if (op == 0) {
                uint256 amount = bound(amounts[i], 0, token.balanceOf(who));
                if (amount > 0) _payIn(who, amount);
            } else if (op == 1) {
                _payInterest(bound(amounts[i], 1, 100));
            } else if (op == 2) {
                uint256 amount = bound(amounts[i], 0, savings.balanceOf(who));
                vm.prank(enforcer);
                savings.setFrozenTokens(who, amount);
            } else {
                uint256 amount = bound(amounts[i], 0, savings.maxWithdraw(who));
                vm.prank(who);
                savings.withdraw(amount, who, who);
            }
            assertGe(token.balanceOf(address(savings)), savings.previewRedeem(savings.totalSupply()));
            assertGe(token.balanceOf(address(savings)), savings.maxWithdraw(alice) + savings.maxWithdraw(bob));
            _assertBooksBalance();
        }
    }

    // Helpers

    function _setRole(address target, bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    function _line(SpikeLedger.Account account, uint256 amount) private pure returns (SpikeLedger.Line[] memory lines) {
        lines = new SpikeLedger.Line[](1);
        lines[0] = SpikeLedger.Line(account, int128(int256(amount)));
    }

    function _cashIn(address to, uint256 amount) private {
        ledger.postWithMint(to, amount, _line(SpikeLedger.Account.Cash, amount), "cash in");
    }

    /// @dev Interest is created into the vault, charged to equity until the chart has an expense line.
    function _payInterest(uint256 amount) private {
        ledger.postWithMint(address(savings), amount, _line(SpikeLedger.Account.Equity, amount), "savings interest");
    }

    function _payIn(address who, uint256 amount) private returns (uint256 shares) {
        vm.startPrank(who);
        token.approve(address(savings), amount);
        shares = savings.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev A hold is a sum of money; it freezes the shares that withdrawing that sum would take.
    function _hold(address who, uint256 amount) private {
        uint256 shares = savings.previewWithdraw(amount);
        vm.prank(enforcer);
        savings.setFrozenTokens(who, shares);
    }

    function _assertBooksBalance() private view {
        int256 sum;
        for (uint8 a = 0; a <= uint8(type(SpikeLedger.Account).max); ++a) sum += ledger.balanceOf(SpikeLedger.Account(a));
        assertEq(sum, 0);
    }
}
