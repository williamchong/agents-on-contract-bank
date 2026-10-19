// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {ERC7913RSAVerifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913RSAVerifier.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Roles} from "../../contracts/core/Roles.sol";
import {PartnerKeys} from "../../contracts/core/PartnerKeys.sol";
import {RsaVector} from "../RsaVector.sol";
import {BankFixture} from "./BankFixture.sol";

/// @dev Checks the partner key register against the partner key rows of the permission matrix in
/// docs/roles.md: governance registers and replaces a key after its delay, IT security revokes one
/// at once, and a partner's signature verifies only under its current key.
contract PartnerKeysTest is BankFixture {
    bytes32 constant CUSTODIAN = keccak256("custodian");
    bytes32 constant DIGEST = keccak256("credit advice");

    uint256 custodianKey = _key("custodian");
    address itSecurity;
    address support;
    address branchManager;

    function setUp() public override {
        super.setUp();
        itSecurity = _staff("itSecurity");
        support = _staff("support");
        branchManager = _staff("branchManager");
        _grantStaff(itSecurity, Roles.IT_SECURITY);
        _grantStaff(support, Roles.SUPPORT);
        _grantStaff(branchManager, Roles.atBranch(1, Roles.BRANCH_MANAGER));
    }

    // Registering

    function test_SetKey_TakesEffectAfterGovernanceDelay() public {
        bytes memory data = abi.encodeCall(PartnerKeys.setKey, (CUSTODIAN, _signer(custodianKey)));
        bytes32 salt = _schedule(address(partnerKeys), data, _quorum());

        vm.warp(block.timestamp + GOVERNANCE_DELAY - 1);
        bytes32 id = timelock.hashOperation(address(partnerKeys), 0, data, bytes32(0), salt);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(1 << uint8(TimelockController.OperationState.Ready))
            )
        );
        timelock.execute(address(partnerKeys), 0, data, bytes32(0), salt);

        vm.warp(block.timestamp + 1);
        timelock.execute(address(partnerKeys), 0, data, bytes32(0), salt);
        assertTrue(partnerKeys.verify(CUSTODIAN, DIGEST, _signP256(custodianKey, DIGEST)));
    }

    function test_SetKey_RecordsTheKey() public {
        bytes memory signer = _signer(custodianKey);
        bytes memory data = abi.encodeCall(PartnerKeys.setKey, (CUSTODIAN, signer));
        bytes32 salt = _schedule(address(partnerKeys), data, _quorum());
        vm.expectEmit(address(partnerKeys));
        emit PartnerKeys.KeySet(CUSTODIAN, signer);
        _execute(address(partnerKeys), data, salt);
        assertEq(partnerKeys.keyOf(CUSTODIAN), signer);
    }

    function test_SetKey_ItSecurityAloneRefused() public {
        bytes memory signer = _signer(custodianKey);
        vm.prank(itSecurity);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, itSecurity));
        partnerKeys.setKey(CUSTODIAN, signer);
    }

    function test_SetKey_ReplacedKeyRefused() public {
        uint256 newKey = _key("clearing, rotated");
        _setKey(CLEARING, _signer(newKey));
        assertFalse(partnerKeys.verify(CLEARING, DIGEST, _signP256(clearingKey, DIGEST)));
        assertTrue(partnerKeys.verify(CLEARING, DIGEST, _signP256(newKey, DIGEST)));
    }

    function test_SetKey_PlainEthereumKeyRefused() public {
        _expectSetKeyRefused(abi.encodePacked(vm.addr(clearingKey)));
    }

    function test_SetKey_VerifierWithoutCodeRefused() public {
        _expectSetKeyRefused(abi.encodePacked(makeAddr("no verifier"), bytes32(0), bytes32(0)));
    }

    function test_SetKey_VerifierWithoutKeyRefused() public {
        _expectSetKeyRefused(abi.encodePacked(address(p256)));
    }

    // Revoking

    function test_RevokeKey_ByItSecurityAtOnce() public {
        vm.expectEmit(address(partnerKeys));
        emit PartnerKeys.KeyRevoked(CLEARING);
        vm.prank(itSecurity);
        partnerKeys.revokeKey(CLEARING);

        assertEq(partnerKeys.keyOf(CLEARING).length, 0);
        assertFalse(partnerKeys.verify(CLEARING, DIGEST, _signP256(clearingKey, DIGEST)));
    }

    function test_RevokeKey_OthersRefused() public {
        address[3] memory others = [support, branchManager, governance];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, others[i]));
            partnerKeys.revokeKey(CLEARING);
        }
    }

    function test_RevokeKey_NewKeyRegisteredAfter() public {
        vm.prank(itSecurity);
        partnerKeys.revokeKey(CLEARING);
        uint256 newKey = _key("clearing, rotated");
        _setKey(CLEARING, _signer(newKey));
        assertTrue(partnerKeys.verify(CLEARING, DIGEST, _signP256(newKey, DIGEST)));
    }

    // Verifying

    function test_Verify_P256OnlyAsSigned() public view {
        bytes memory sig = _signP256(clearingKey, DIGEST);
        assertTrue(partnerKeys.verify(CLEARING, DIGEST, sig));
        assertFalse(partnerKeys.verify(CLEARING, keccak256("another digest"), sig));
        assertFalse(partnerKeys.verify(CLEARING, DIGEST, _signP256(_key("someone else"), DIGEST)));
    }

    function test_Verify_P256HighSFormRefused() public view {
        bytes memory sig = _signP256(clearingKey, DIGEST);
        (bytes32 r, bytes32 s) = abi.decode(sig, (bytes32, bytes32));
        assertFalse(partnerKeys.verify(CLEARING, DIGEST, abi.encodePacked(r, P256.N - uint256(s))));
    }

    function test_Verify_UnregisteredPartnerRefused() public view {
        assertFalse(partnerKeys.verify(CUSTODIAN, DIGEST, _signP256(clearingKey, DIGEST)));
    }

    function test_Verify_RsaPartner() public {
        ERC7913RSAVerifier rsa = new ERC7913RSAVerifier();
        _setKey(CUSTODIAN, abi.encodePacked(address(rsa), abi.encode(RsaVector.E, RsaVector.N)));

        assertTrue(partnerKeys.verify(CUSTODIAN, RsaVector.DIGEST, RsaVector.SIG));
        bytes memory flipped = RsaVector.SIG;
        flipped[255] ^= 0x01;
        assertFalse(partnerKeys.verify(CUSTODIAN, RsaVector.DIGEST, flipped));
        assertFalse(partnerKeys.verify(CUSTODIAN, DIGEST, RsaVector.SIG));
    }

    // Helpers

    function _setKey(bytes32 partner, bytes memory signer) private {
        _govern(address(partnerKeys), abi.encodeCall(PartnerKeys.setKey, (partner, signer)));
    }

    /// @dev Governance's decision is carried out by the time lock, which reverts with the
    /// register's own error.
    function _expectSetKeyRefused(bytes memory signer) private {
        bytes memory data = abi.encodeCall(PartnerKeys.setKey, (CUSTODIAN, signer));
        bytes32 salt = _schedule(address(partnerKeys), data, _quorum());
        vm.expectRevert(abi.encodeWithSelector(PartnerKeys.NotAVerifierKey.selector, signer));
        _execute(address(partnerKeys), data, salt);
    }
}
