// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {ERC20Restricted} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";
import {IERC7943Fungible} from "@openzeppelin/community-contracts/contracts/interfaces/IERC7943.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {DepositToken} from "../../contracts/core/DepositToken.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the deposit token's allow-list, block-list, freezes, forced transfers and
/// customer-signed transfers, from the opening balance sheet.
contract DepositTokenTest is BankFixture {
    bytes32 constant TRANSFER_TYPEHASH =
        keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );

    address enforcer = makeAddr("enforcer");
    address freezer = makeAddr("freezer");
    address compliance = makeAddr("compliance");
    address carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        manager.grantRole(Roles.ENFORCER, enforcer, 0);
        manager.grantRole(Roles.FREEZER, freezer, 0);
        manager.grantRole(Roles.COMPLIANCE, compliance, 0);
    }

    function test_CountsInCents() public view {
        assertEq(token.decimals(), 2);
    }

    // Allow-list and block-list

    function test_AllowList_RefusesUnadmittedRecipient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20Restricted.ERC20UserRestricted.selector, carol));
        token.transfer(carol, 1);
    }

    function test_BlockList_RefusesSendingAndReceiving() public {
        vm.prank(compliance);
        token.blockUser(alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20Restricted.ERC20UserRestricted.selector, alice));
        token.transfer(bob, 1);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC20Restricted.ERC20UserRestricted.selector, alice));
        token.transfer(alice, 1);
    }

    function test_BlockList_ForcedTransferStillTakesTheMoney() public {
        vm.prank(compliance);
        token.blockUser(alice);
        vm.prank(enforcer);
        token.forcedTransfer(alice, pending, 10);
        assertEq(token.balanceOf(pending), 10);
    }

    function test_BlockList_LiftedReadmits() public {
        vm.prank(compliance);
        token.blockUser(alice);
        token.unblockUser(alice);

        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 100_000 * HKD + 1);
    }

    function test_BlockList_OnlyAdmittedAccounts() public {
        vm.prank(compliance);
        vm.expectRevert(abi.encodeWithSelector(DepositToken.NotAdmitted.selector, carol));
        token.blockUser(carol);
    }

    function test_BlockList_LiftingNeverAdmits() public {
        vm.expectRevert(abi.encodeWithSelector(DepositToken.NotBlocked.selector, carol));
        token.unblockUser(carol);
        vm.expectRevert(abi.encodeWithSelector(DepositToken.NotBlocked.selector, alice));
        token.unblockUser(alice);
    }

    // Freezes and forced transfers

    function test_Freeze_BlocksOwnTransfer() public {
        uint256 held = token.balanceOf(alice);
        vm.prank(freezer);
        token.setFrozenTokens(alice, held - 20);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, alice, 30, 20));
        token.transfer(bob, 30);
    }

    function test_ForcedTransfer_CutsThroughFreezeAndLowersIt() public {
        uint256 held = token.balanceOf(alice);
        vm.prank(freezer);
        token.setFrozenTokens(alice, held);
        vm.prank(enforcer);
        token.forcedTransfer(alice, bob, 50);

        assertEq(token.balanceOf(bob), 100_000 * HKD + 50);
        assertEq(token.getFrozenTokens(alice), held - 50);
    }

    function test_ForcedTransfer_StillChecksRecipient() public {
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, carol));
        token.forcedTransfer(alice, carol, 10);
    }

    function test_ForcedTransfer_FromNothingRefused() public {
        uint256 supply = token.totalSupply();
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.forcedTransfer(address(0), bob, 10);
        assertEq(token.totalSupply(), supply);
    }

    // Customer-signed transfers

    function test_TransferByAuthorization() public {
        (address dave, uint256 daveKey) = _fundedSigner();
        bytes memory sig = _sign(daveKey, dave, bob, 30, 0);
        _transferWithAuthorization(dave, 30, 0, sig);
        assertEq(token.balanceOf(bob), 100_000 * HKD + 30);

        vm.expectRevert(abi.encodeWithSelector(Nonces.InvalidAccountNonce.selector, dave, 1));
        _transferWithAuthorization(dave, 30, 0, sig);
    }

    function test_TransferByAuthorization_OtherAmountRefused() public {
        (address dave, uint256 daveKey) = _fundedSigner();
        bytes memory sig = _sign(daveKey, dave, bob, 30, 0);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(dave, 31, 0, sig);
    }

    /// @dev An admitted holder with a plain key of its own, funded from alice.
    function _fundedSigner() private returns (address signer, uint256 key) {
        (signer, key) = makeAddrAndKey("dave");
        token.allowUser(signer);
        vm.prank(alice);
        token.transfer(signer, 100);
    }

    function _transferWithAuthorization(address from, uint256 value, bytes32 nonce, bytes memory sig) private {
        token.transferWithAuthorization(from, bob, value, 0, block.timestamp + 1 hours, nonce, sig);
    }

    function _sign(
        uint256 key,
        address from,
        address to,
        uint256 value,
        bytes32 nonce
    ) private view returns (bytes memory) {
        (, string memory name, string memory version, , , , ) = token.eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(token)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(TRANSFER_TYPEHASH, from, to, value, 0, block.timestamp + 1 hours, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toTypedDataHash(domain, structHash));
        return abi.encodePacked(r, s, v);
    }
}
