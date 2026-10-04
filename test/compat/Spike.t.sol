// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC7739Utils} from "@openzeppelin/contracts/utils/cryptography/draft-ERC7739Utils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {ERC20Restricted} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";
import {IERC7943Fungible} from "@openzeppelin/community-contracts/contracts/interfaces/IERC7943.sol";
import {RoleAccountFactory} from "@openzeppelin/community-contracts/contracts/account/RoleAccountFactory.sol";
import {SpikeDepositToken} from "../../contracts/spike/SpikeDepositToken.sol";
import {SpikeCustomerAccount} from "../../contracts/spike/SpikeCustomerAccount.sol";
import {SpikeRecovery} from "../../contracts/spike/SpikeRecovery.sol";

/// @dev Checks that the pinned OpenZeppelin main and community libraries work together on the
/// local chain for the pieces milestone 2 rests on. See open questions 1, 2 and 7 in docs/plan.md.
contract SpikeTest is Test {
    uint64 constant ENFORCER = 1;
    uint64 constant RECOVERY_OFFICER = 2;
    uint64 constant TELLER = 3;

    string constant CONTENTS_TYPE =
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)";

    AccessManager manager;
    SpikeDepositToken token;
    SpikeRecovery recovery;
    SpikeCustomerAccount customer;

    uint256 device1;
    uint256 device2;
    uint256 device3;
    uint256 validBefore;
    address enforcer = makeAddr("enforcer");
    address officer = makeAddr("officer");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        device1 = makeAccount("device1").key;
        device2 = makeAccount("device2").key;
        device3 = makeAccount("device3").key;
        validBefore = block.timestamp + 1 hours;

        manager = new AccessManager(address(this));
        token = new SpikeDepositToken(address(manager));
        recovery = new SpikeRecovery(address(manager));

        _setRole(address(token), token.forcedTransfer.selector, ENFORCER);
        _setRole(address(token), token.setFrozenTokens.selector, ENFORCER);
        _setRole(address(recovery), recovery.replaceSigner.selector, RECOVERY_OFFICER);
        manager.grantRole(ENFORCER, enforcer, 0);
        manager.grantRole(RECOVERY_OFFICER, officer, 0);

        customer = new SpikeCustomerAccount(address(recovery), _signers(_keys(device1, device2)), 2);

        token.allowUser(address(customer));
        token.allowUser(bob);
        token.mint(address(customer), 100);
    }

    // Tokens

    function test_TransferByAuthorization_AtThreshold() public {
        _payBob(address(customer), 30, 0, _customerSig(_keys(device1, device2), 30, 0));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_TransferByAuthorization_BelowThresholdRefused() public {
        bytes memory sig = _customerSig(_keys(device1), 30, 0);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _payBob(address(customer), 30, 0, sig);
    }

    function test_AllowList_RefusesUnadmittedRecipient() public {
        vm.prank(address(customer));
        vm.expectRevert(abi.encodeWithSelector(ERC20Restricted.ERC20UserRestricted.selector, carol));
        token.transfer(carol, 1);
    }

    function test_Freeze_BlocksOwnTransfer() public {
        vm.prank(enforcer);
        token.setFrozenTokens(address(customer), 80);

        bytes memory sig = _customerSig(_keys(device1, device2), 30, 0);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20Freezable.ERC20InsufficientUnfrozenBalance.selector, address(customer), 30, 20)
        );
        _payBob(address(customer), 30, 0, sig);
    }

    function test_ForcedTransfer_CutsThroughFreezeAndLowersIt() public {
        vm.startPrank(enforcer);
        token.setFrozenTokens(address(customer), 80);
        token.forcedTransfer(address(customer), bob, 50);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 50);
        assertEq(token.getFrozenTokens(address(customer)), 50);
    }

    function test_ForcedTransfer_StillChecksRecipient() public {
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IERC7943Fungible.ERC7943CannotReceive.selector, carol));
        token.forcedTransfer(address(customer), carol, 10);
    }

    function test_ForcedTransfer_OnlyEnforcer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        token.forcedTransfer(address(customer), bob, 10);
    }

    // Account recovery

    function test_Recovery_ReplacesLostDevice() public {
        vm.prank(officer);
        recovery.replaceSigner(customer, _signerBytes(device2), _signerBytes(device3));

        bytes memory oldSig = _customerSig(_keys(device1, device2), 30, 0);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _payBob(address(customer), 30, 0, oldSig);

        _payBob(address(customer), 30, 0, _customerSig(_keys(device1, device3), 30, 0));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_Recovery_OnlyOfficer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        recovery.replaceSigner(customer, _signerBytes(device2), _signerBytes(device3));
    }

    function test_Recovery_ModuleCannotExecuteOrMoveMoney() public {
        vm.startPrank(address(recovery));
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, address(recovery)));
        customer.execute(bytes32(uint256(0x01) << 248), "");

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(recovery), 0, 10)
        );
        token.transferFrom(address(customer), bob, 10);
        vm.stopPrank();
    }

    function test_Recovery_OthersCannotChangeSigners() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OZAccount.AccountUnauthorized.selector, bob));
        customer.addSigners(_signers(_keys(device3)));
    }

    // Bank-owned account controlled by a role

    function test_RoleAccount_SignsWhileMemberOnly() public {
        (address teller, uint256 tellerKey) = makeAddrAndKey("teller");
        address till = new RoleAccountFactory().deployRoleAccount(address(manager), TELLER);
        manager.grantRole(TELLER, teller, 0);
        token.allowUser(till);
        token.mint(till, 100);

        _payBob(till, 40, 0, _roleSig(till, tellerKey, 40, 0));
        assertEq(token.balanceOf(bob), 40);

        manager.revokeRole(TELLER, teller);
        bytes memory sig = _roleSig(till, tellerKey, 40, bytes32(uint256(1)));
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _payBob(till, 40, bytes32(uint256(1)), sig);
    }

    // Helpers

    function _setRole(address target, bytes4 selector, uint64 role) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        manager.setTargetFunctionRole(target, selectors, role);
    }

    function _keys(uint256 a) private pure returns (uint256[] memory keys) {
        keys = new uint256[](1);
        keys[0] = a;
    }

    function _keys(uint256 a, uint256 b) private pure returns (uint256[] memory keys) {
        keys = new uint256[](2);
        keys[0] = a;
        keys[1] = b;
    }

    function _signerBytes(uint256 key) private pure returns (bytes memory) {
        return abi.encodePacked(vm.addr(key));
    }

    function _signers(uint256[] memory keys) private pure returns (bytes[] memory signers) {
        signers = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) signers[i] = _signerBytes(keys[i]);
    }

    function _payBob(address from, uint256 value, bytes32 nonce, bytes memory sig) private {
        token.transferWithAuthorization(from, bob, value, 0, validBefore, nonce, sig);
    }

    function _customerSig(uint256[] memory keys, uint256 value, bytes32 nonce) private view returns (bytes memory) {
        bytes32 digest = _digest(address(customer), "SpikeCustomerAccount", value, nonce);
        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) sigs[i] = _ecdsa(keys[i], digest);
        return _wrap(abi.encode(_signers(keys), sigs), address(customer), value, nonce);
    }

    /// @dev A role account's signature names the signer, so the account can check the role.
    function _roleSig(address till, uint256 key, uint256 value, bytes32 nonce) private view returns (bytes memory) {
        bytes memory sig = abi.encodePacked(vm.addr(key), _ecdsa(key, _digest(till, "RoleAccount", value, nonce)));
        return _wrap(sig, till, value, nonce);
    }

    function _contentsHash(address from, uint256 value, bytes32 nonce) private view returns (bytes32) {
        return keccak256(abi.encode(keccak256(bytes(CONTENTS_TYPE)), from, bob, value, 0, validBefore, nonce));
    }

    function _tokenSeparator() private view returns (bytes32) {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifying, bytes32 salt, ) = token
            .eip712Domain();
        return MessageHashUtils.toDomainSeparator(fields, name, version, chainId, verifying, salt);
    }

    /// @dev The digest a smart account's signers sign under ERC-7739: the token's transfer
    /// authorisation, nested in a `TypedDataSign` that binds it to that one account.
    function _digest(address account, string memory name, uint256 value, bytes32 nonce) private view returns (bytes32) {
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "TypedDataSign(TransferWithAuthorization contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)",
                CONTENTS_TYPE
            )
        );
        bytes memory accountDomain = abi.encode(keccak256(bytes(name)), keccak256("1"), block.chainid, account, bytes32(0));
        bytes32 structHash = keccak256(abi.encodePacked(typehash, _contentsHash(account, value, nonce), accountDomain));
        return MessageHashUtils.toTypedDataHash(_tokenSeparator(), structHash);
    }

    /// @dev Encodes the account's own signature in the ERC-7739 form the account checks under ERC-1271.
    function _wrap(bytes memory inner, address from, uint256 value, bytes32 nonce) private view returns (bytes memory) {
        return ERC7739Utils.encodeTypedDataSig(inner, _tokenSeparator(), _contentsHash(from, value, nonce), CONTENTS_TYPE);
    }

    function _ecdsa(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
