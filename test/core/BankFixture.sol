// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {GeneralLedger} from "../../contracts/core/GeneralLedger.sol";

/// @dev Deploys the core contracts, wires each restricted function to its role in docs/roles.md
/// and posts the opening balance sheet in docs/scenarios.md. The test contract stands in for the
/// governance time lock, so it holds the admin and governance roles.
abstract contract BankFixture is Test {
    /// @dev One Hong Kong dollar, in the token's cents.
    uint256 constant HKD = 100;

    AccessManager manager;
    DepositToken token;
    GeneralLedger ledger;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    /// @dev Every other customer's deposits on the opening balance sheet, held together.
    address otherCustomers = makeAddr("otherCustomers");
    /// @dev A bank-owned account, such as pending withdrawals.
    address pending = makeAddr("pending");

    function setUp() public virtual {
        manager = new AccessManager(address(this));
        token = new DepositToken(address(manager));
        ledger = new GeneralLedger(address(manager), token);

        _wire(address(token), token.mint.selector, Roles.LEDGER);
        _wire(address(token), token.burn.selector, Roles.LEDGER);
        _wire(address(token), token.forcedTransfer.selector, Roles.ENFORCER);
        _wire(address(token), token.setFrozenTokens.selector, Roles.FREEZER);
        _wire(address(token), token.blockUser.selector, Roles.COMPLIANCE);
        _wire(address(token), token.unblockUser.selector, Roles.GOVERNANCE);
        _wire(address(ledger), ledger.post.selector, Roles.BOOKKEEPER);
        _wire(address(ledger), ledger.postWithMint.selector, Roles.BOOKKEEPER);
        _wire(address(ledger), ledger.postWithBurn.selector, Roles.BOOKKEEPER);
        _wire(address(ledger), ledger.postOpening.selector, Roles.GOVERNANCE);

        manager.grantRole(Roles.LEDGER, address(ledger), 0);
        manager.grantRole(Roles.GOVERNANCE, address(this), 0);

        token.allowUser(alice);
        token.allowUser(bob);
        token.allowUser(otherCustomers);
        token.allowUser(pending);

        _postOpening();
    }

    function _postOpening() private {
        address[] memory holders = new address[](3);
        holders[0] = alice;
        holders[1] = bob;
        holders[2] = otherCustomers;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100_000 * HKD;
        amounts[1] = 100_000 * HKD;
        amounts[2] = 12_100_000 * HKD;

        GeneralLedger.Line[] memory lines = new GeneralLedger.Line[](6);
        lines[0] = GeneralLedger.Line(GeneralLedger.Account.Settlement, _hkd(1_000_000));
        lines[1] = GeneralLedger.Line(GeneralLedger.Account.Cash, _hkd(500_000));
        lines[2] = GeneralLedger.Line(GeneralLedger.Account.Securities, _hkd(2_500_000));
        lines[3] = GeneralLedger.Line(GeneralLedger.Account.Loans, _hkd(9_300_000));
        lines[4] = GeneralLedger.Line(GeneralLedger.Account.Allowance, -_hkd(93_000));
        lines[5] = GeneralLedger.Line(GeneralLedger.Account.Equity, -_hkd(907_000));

        ledger.postOpening(holders, amounts, lines, "opening");
    }

    function _wire(address target, bytes4 selector, uint64 role) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    function _hkd(int128 amount) internal pure returns (int128) {
        return amount * int128(int256(HKD));
    }

    function _assertBooksBalance() internal view {
        int256[] memory all = ledger.balances();
        int256 sum;
        for (uint256 i = 0; i < all.length; ++i) sum += all[i];
        assertEq(sum, 0, "assets equal liabilities and equity");
    }
}
