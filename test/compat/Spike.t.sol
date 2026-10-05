// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Account as OZAccount} from "@openzeppelin/contracts/account/Account.sol";
import {ERC3009} from "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC3009.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC7913SignatureVerifier} from "@openzeppelin/contracts/interfaces/IERC7913.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC7739Utils} from "@openzeppelin/contracts/utils/cryptography/draft-ERC7739Utils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import {ERC7913P256Verifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol";
import {ERC7913WebAuthnVerifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913WebAuthnVerifier.sol";
import {ERC20Freezable} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Freezable.sol";
import {ERC20Restricted} from "@openzeppelin/community-contracts/contracts/token/ERC20/extensions/ERC20Restricted.sol";
import {IERC7943Fungible} from "@openzeppelin/community-contracts/contracts/interfaces/IERC7943.sol";
import {RoleAccountFactory} from "@openzeppelin/community-contracts/contracts/account/RoleAccountFactory.sol";
import {SpikeDepositToken} from "../../contracts/spike/SpikeDepositToken.sol";
import {SpikeCustomerAccount, SpikeDeviceKeys} from "../../contracts/spike/SpikeCustomerAccount.sol";
import {SpikeRecovery} from "../../contracts/spike/SpikeRecovery.sol";

/// @dev A verifier that accepts every signature, which an account must never let in as a device.
contract AcceptAllVerifier is IERC7913SignatureVerifier {
    function verify(bytes calldata, bytes32, bytes calldata) external pure returns (bytes4) {
        return IERC7913SignatureVerifier.verify.selector;
    }
}

/// @dev Checks that the pinned OpenZeppelin main and community libraries work together on the
/// local chain for the pieces milestone 2 rests on. Customer devices are passkeys signing WebAuthn
/// assertions, and chip cards signing with P-256. See open questions 1, 2 and 7 in docs/plan.md.
contract SpikeTest is Test {
    uint64 constant ENFORCER = 1;
    uint64 constant RECOVERY_OFFICER = 2;
    uint64 constant TELLER = 3;

    /// @dev Authenticator data flags: user present, user verified, backup eligible, backed up.
    bytes1 constant UP = 0x01;
    bytes1 constant UV = 0x04;
    bytes1 constant BE = 0x08;
    bytes1 constant BS = 0x10;

    /// @dev A real assertion from Chrome 154's virtual authenticator, over the challenge
    /// sha256("spike passkey digest"), made with a credential created for rpId "localhost" and
    /// navigator.credentials.get with userVerification "required".
    bytes32 constant CHROME_QX = 0xd0684eb8b46d78bc5afa3d1528c881cd8dd2934ebdc68c90dc65b07a55a5afef;
    bytes32 constant CHROME_QY = 0xdd9b7eec887febd32fa8dbccbc106601118a2f48f288b2b78043abe73fc6245a;
    bytes32 constant CHROME_R = 0x76134b7b5356855b897b29aec54ca9f22ac84025a2a06bd241a5597bb13ff449;
    bytes32 constant CHROME_S = 0x57340ef8dddef49d532d1f5a4ec0a4ffa5c00288fe66819d27470b8069c5a07b;
    bytes constant CHROME_AUTH_DATA = hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630500000002";
    string constant CHROME_CLIENT_DATA =
        '{"type":"webauthn.get","challenge":"k9IYlWp_HAAmXuBwV_1Gtaad5WKnrSdwsDBCARkDVUg","origin":"http://localhost:8765","crossOrigin":false}';

    /// @dev Where "type" and "challenge" start in client data that opens {"type":"webauthn.get",
    /// as Chrome's does. Browsers put them first, but the verifier is told and does not search.
    uint256 constant TYPE_INDEX = 1;
    uint256 constant CHALLENGE_INDEX = 23;

    string constant CONTENTS_TYPE =
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)";

    AccessManager manager;
    SpikeDepositToken token;
    SpikeRecovery recovery;
    SpikeCustomerAccount customer;
    ERC7913WebAuthnVerifier passkeyVerifier;
    ERC7913P256Verifier cardVerifier;

    uint256 device1 = 0xD1;
    uint256 device2 = 0xD2;
    uint256 device3 = 0xD3;
    uint256 card = 0xCA;
    uint256 validBefore;
    address enforcer = makeAddr("enforcer");
    address officer = makeAddr("officer");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        validBefore = block.timestamp + 1 hours;

        manager = new AccessManager(address(this));
        token = new SpikeDepositToken(address(manager));
        recovery = new SpikeRecovery(address(manager));
        passkeyVerifier = new ERC7913WebAuthnVerifier();
        cardVerifier = new ERC7913P256Verifier();

        _setRole(address(token), token.forcedTransfer.selector, ENFORCER);
        _setRole(address(token), token.setFrozenTokens.selector, ENFORCER);
        _setRole(address(recovery), recovery.replaceSigner.selector, RECOVERY_OFFICER);
        manager.grantRole(ENFORCER, enforcer, 0);
        manager.grantRole(RECOVERY_OFFICER, officer, 0);

        customer = _account(_signers(_keys(device1, device2)), 2);
        token.allowUser(bob);
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

    function test_ForcedTransfer_FromNothingRefused() public {
        vm.prank(enforcer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.forcedTransfer(address(0), bob, 10);
        assertEq(token.totalSupply(), 100);
    }

    function test_ForcedTransfer_OnlyEnforcer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        token.forcedTransfer(address(customer), bob, 10);
    }

    // Account recovery

    function test_Recovery_ReplacesLostDevice() public {
        vm.prank(officer);
        recovery.replaceSigner(customer, _passkey(device2), _passkey(device3));

        bytes memory oldSig = _customerSig(_keys(device1, device2), 30, 0);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _payBob(address(customer), 30, 0, oldSig);

        _payBob(address(customer), 30, 0, _customerSig(_keys(device1, device3), 30, 0));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_Recovery_OnlyOfficer() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, bob));
        recovery.replaceSigner(customer, _passkey(device2), _passkey(device3));
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

    // Passkeys and cards

    function test_Passkey_PhoneAloneAtThresholdOne() public {
        address phone = _phone();
        _payBob(phone, 30, 0, _phoneSig(phone, _phoneAuth(phone, UP | UV)));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_Passkey_SyncedAccepted() public {
        address phone = _phone();
        _payBob(phone, 30, 0, _phoneSig(phone, _phoneAuth(phone, UP | UV | BE | BS)));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_Passkey_WithCardAtThreshold() public {
        bytes[] memory signers = new bytes[](2);
        signers[0] = _passkey(device1);
        signers[1] = _card(card);
        address account = address(_account(signers, 2));

        bytes32 digest = _digest(account, "SpikeCustomerAccount", 30, 0);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _encode(_auth(device1, digest, UP | UV));
        (bytes32 r, bytes32 s) = _p256(card, digest);
        sigs[1] = abi.encodePacked(r, s);

        _payBob(account, 30, 0, _wrap(abi.encode(signers, sigs), account, 30, 0));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_Passkey_WithoutUserVerificationRefused() public {
        address phone = _phone();
        _assertPhoneRefused(phone, _phoneAuth(phone, UP));
    }

    function test_Passkey_WithoutUserPresenceRefused() public {
        address phone = _phone();
        _assertPhoneRefused(phone, _phoneAuth(phone, UV));
    }

    function test_Passkey_BackedUpButNotEligibleRefused() public {
        address phone = _phone();
        _assertPhoneRefused(phone, _phoneAuth(phone, UP | UV | BS));
    }

    function test_Passkey_CreationCeremonyRefused() public {
        address phone = _phone();
        WebAuthn.WebAuthnAuth memory auth = _phoneAuth(phone, UP | UV);
        auth.clientDataJSON = _clientData("webauthn.create", _digest(phone, "SpikeCustomerAccount", 30, 0), "https://bank.example");
        _sign(device1, auth);
        _assertPhoneRefused(phone, auth);
    }

    function test_Passkey_AmountChangedRefused() public {
        address phone = _phone();
        _assertPhoneRefused(phone, _auth(device1, _digest(phone, "SpikeCustomerAccount", 31, 0), UP | UV));
    }

    function test_Passkey_HighSFormRefused() public {
        address phone = _phone();
        WebAuthn.WebAuthnAuth memory auth = _phoneAuth(phone, UP | UV);
        auth.s = bytes32(P256.N - uint256(auth.s));
        _assertPhoneRefused(phone, auth);
    }

    function test_Passkey_ShortAuthenticatorDataRefused() public {
        address phone = _phone();
        WebAuthn.WebAuthnAuth memory auth = _phoneAuth(phone, UP | UV);
        auth.authenticatorData = abi.encodePacked(sha256("bank.example"), UP | UV, bytes3(0));
        _sign(device1, auth);
        _assertPhoneRefused(phone, auth);
    }

    function test_Passkey_UnregisteredRefused() public {
        address phone = _phone();
        bytes32 digest = _digest(phone, "SpikeCustomerAccount", 30, 0);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _encode(_auth(device3, digest, UP | UV));
        bytes memory sig = _wrap(abi.encode(_signers(_keys(device3)), sigs), phone, 30, 0);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _payBob(phone, 30, 0, sig);
    }

    /// @dev The chain does not check which site asked for the assertion. The challenge is the
    /// exact authorisation, so a page on another site can only get the customer to sign what
    /// they would have signed anyway.
    function test_Passkey_OtherSiteNotChecked() public {
        address phone = _phone();
        WebAuthn.WebAuthnAuth memory auth = _phoneAuth(phone, UP | UV);
        auth.authenticatorData = abi.encodePacked(sha256("other.example"), UP | UV, uint32(1));
        auth.clientDataJSON = _clientData("webauthn.get", _digest(phone, "SpikeCustomerAccount", 30, 0), "https://other.example");
        _sign(device1, auth);
        _payBob(phone, 30, 0, _phoneSig(phone, auth));
        assertEq(token.balanceOf(bob), 30);
    }

    function test_Passkey_ChromeVectorVerifies() public view {
        bytes memory key = abi.encodePacked(CHROME_QX, CHROME_QY);
        bytes32 challenge = sha256("spike passkey digest");
        WebAuthn.WebAuthnAuth memory auth = WebAuthn.WebAuthnAuth({
            r: CHROME_R,
            s: CHROME_S,
            challengeIndex: CHALLENGE_INDEX,
            typeIndex: TYPE_INDEX,
            authenticatorData: CHROME_AUTH_DATA,
            clientDataJSON: CHROME_CLIENT_DATA
        });
        assertEq(passkeyVerifier.verify(key, challenge, _encode(auth)), IERC7913SignatureVerifier.verify.selector);
        assertEq(passkeyVerifier.verify(key, keccak256("another digest"), _encode(auth)), bytes4(0xFFFFFFFF));

        auth.s = bytes32(P256.N - uint256(CHROME_S));
        assertEq(passkeyVerifier.verify(key, challenge, _encode(auth)), bytes4(0xFFFFFFFF));
    }

    function test_DeviceKey_PlainEthereumKeyRefused() public {
        bytes[] memory signers = new bytes[](1);
        signers[0] = abi.encodePacked(vm.addr(device1));
        vm.expectRevert(abi.encodeWithSelector(SpikeDeviceKeys.NotADeviceKey.selector, signers[0]));
        new SpikeCustomerAccount(address(recovery), address(passkeyVerifier), address(cardVerifier), signers, 1);
    }

    function test_DeviceKey_MalformedKeyRefused() public {
        bytes[] memory signers = new bytes[](1);
        signers[0] = abi.encodePacked(address(passkeyVerifier), bytes32(0));
        vm.prank(address(customer));
        vm.expectRevert(abi.encodeWithSelector(SpikeDeviceKeys.NotADeviceKey.selector, signers[0]));
        customer.addSigners(signers);
    }

    function test_DeviceKey_UnapprovedVerifierRefused() public {
        bytes[] memory signers = new bytes[](1);
        signers[0] = abi.encodePacked(address(new AcceptAllVerifier()), bytes32(0), bytes32(0));

        vm.prank(address(customer));
        vm.expectRevert(abi.encodeWithSelector(SpikeDeviceKeys.NotADeviceKey.selector, signers[0]));
        customer.addSigners(signers);

        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(SpikeDeviceKeys.NotADeviceKey.selector, signers[0]));
        recovery.replaceSigner(customer, _passkey(device2), signers[0]);
    }

    // Cost

    /// @dev Logs what one device's signature check costs by key type, and the whole transfer
    /// authorisation from a passkey-only account. The transfer's figure leaves out the
    /// transaction's base cost and calldata.
    function test_Gas_DeviceCheckByKeyType() public {
        bytes32 hash = keccak256("device check");
        bytes memory assertion = _encode(_auth(device1, hash, UP | UV));
        (bytes32 r, bytes32 s) = _p256(card, hash);
        (uint256 x, uint256 y) = vm.publicKeyP256(device1);
        (uint256 cx, uint256 cy) = vm.publicKeyP256(card);

        uint256 before = gasleft();
        passkeyVerifier.verify(abi.encodePacked(x, y), hash, assertion);
        uint256 passkeyGas = before - gasleft();

        before = gasleft();
        cardVerifier.verify(abi.encodePacked(cx, cy), hash, abi.encodePacked(r, s));
        uint256 cardGas = before - gasleft();

        address phone = _phone();
        bytes memory sig = _phoneSig(phone, _phoneAuth(phone, UP | UV));
        before = gasleft();
        _payBob(phone, 30, 0, sig);
        uint256 transferGas = before - gasleft();

        console.log("Passkey (WebAuthn) check gas:", passkeyGas);
        console.log("Card (P-256) check gas:", cardGas);
        console.log("Transfer by one passkey, whole call gas:", transferGas);
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

    function _account(bytes[] memory signers, uint64 threshold) private returns (SpikeCustomerAccount account) {
        account = new SpikeCustomerAccount(
            address(recovery),
            address(passkeyVerifier),
            address(cardVerifier),
            signers,
            threshold
        );
        token.allowUser(address(account));
        token.mint(address(account), 100);
    }

    function _phone() private returns (address) {
        return address(_account(_signers(_keys(device1)), 1));
    }

    function _passkey(uint256 key) private view returns (bytes memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        return abi.encodePacked(address(passkeyVerifier), x, y);
    }

    function _card(uint256 key) private view returns (bytes memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        return abi.encodePacked(address(cardVerifier), x, y);
    }

    function _signers(uint256[] memory keys) private view returns (bytes[] memory signers) {
        signers = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) signers[i] = _passkey(keys[i]);
    }

    function _payBob(address from, uint256 value, bytes32 nonce, bytes memory sig) private {
        token.transferWithAuthorization(from, bob, value, 0, validBefore, nonce, sig);
    }

    function _customerSig(uint256[] memory keys, uint256 value, bytes32 nonce) private view returns (bytes memory) {
        bytes32 digest = _digest(address(customer), "SpikeCustomerAccount", value, nonce);
        bytes[] memory sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; ++i) sigs[i] = _encode(_auth(keys[i], digest, UP | UV));
        return _wrap(abi.encode(_signers(keys), sigs), address(customer), value, nonce);
    }

    function _phoneSig(address phone, WebAuthn.WebAuthnAuth memory auth) private view returns (bytes memory) {
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _encode(auth);
        return _wrap(abi.encode(_signers(_keys(device1)), sigs), phone, 30, 0);
    }

    function _assertPhoneRefused(address phone, WebAuthn.WebAuthnAuth memory auth) private {
        bytes memory sig = _phoneSig(phone, auth);
        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _payBob(phone, 30, 0, sig);
    }

    function _phoneAuth(address phone, bytes1 flags) private view returns (WebAuthn.WebAuthnAuth memory) {
        return _auth(device1, _digest(phone, "SpikeCustomerAccount", 30, 0), flags);
    }

    /// @dev A WebAuthn assertion as a browser returns it, with the challenge set to the digest.
    function _auth(uint256 key, bytes32 digest, bytes1 flags) private pure returns (WebAuthn.WebAuthnAuth memory auth) {
        auth.typeIndex = TYPE_INDEX;
        auth.challengeIndex = CHALLENGE_INDEX;
        auth.authenticatorData = abi.encodePacked(sha256("bank.example"), flags, uint32(1));
        auth.clientDataJSON = _clientData("webauthn.get", digest, "https://bank.example");
        _sign(key, auth);
    }

    function _clientData(string memory type_, bytes32 digest, string memory origin) private pure returns (string memory) {
        return
            string.concat(
                '{"type":"',
                type_,
                '","challenge":"',
                Base64.encodeURL(abi.encodePacked(digest)),
                '","origin":"',
                origin,
                '","crossOrigin":false}'
            );
    }

    /// @dev The verifier reads the assertion's fields as a flat tuple, not as an encoded struct,
    /// which would put an offset word in front of them.
    function _encode(WebAuthn.WebAuthnAuth memory auth) private pure returns (bytes memory) {
        return abi.encode(auth.r, auth.s, auth.challengeIndex, auth.typeIndex, auth.authenticatorData, auth.clientDataJSON);
    }

    /// @dev The authenticator signs its data followed by the SHA-256 of the client data.
    function _sign(uint256 key, WebAuthn.WebAuthnAuth memory auth) private pure {
        bytes32 signed = sha256(abi.encodePacked(auth.authenticatorData, sha256(bytes(auth.clientDataJSON))));
        (auth.r, auth.s) = _p256(key, signed);
    }

    /// @dev P-256 signatures are accepted only in their low-s form, so the high form is folded down.
    function _p256(uint256 key, bytes32 digest) private pure returns (bytes32 r, bytes32 s) {
        (r, s) = vm.signP256(key, digest);
        if (uint256(s) > P256.N / 2) s = bytes32(P256.N - uint256(s));
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
