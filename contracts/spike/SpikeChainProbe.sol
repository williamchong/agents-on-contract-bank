// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC7913SignatureVerifier} from "@openzeppelin/contracts/interfaces/IERC7913.sol";
import {ERC7913P256Verifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913P256Verifier.sol";
import {ERC7913RSAVerifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913RSAVerifier.sol";
import {ERC7913WebAuthnVerifier} from "@openzeppelin/contracts/utils/cryptography/verifiers/ERC7913WebAuthnVerifier.sol";

/// @dev Chain probe: checks on a live chain what a forked test cannot, because a fork runs the
/// local engine's own precompiles. It is placed on the chain by a state override and called by
/// eth_call, so it needs no key, gas or deployment. It reports whether the P-256 precompile is
/// there, and what the precompile, a card check, a passkey check and an RSA partner's check each
/// cost, and reverts if any signature is judged wrongly. See scripts/probe-chain.ts and open
/// question 1 in docs/plan.md.
contract SpikeChainProbe {
    /// @dev The precompile that RIP-7212 and EIP-7951 both place at this address.
    address constant P256_VERIFY = address(0x100);

    /// @dev The real Chrome assertion from the passkey tests in test/compat/Spike.t.sol. Its
    /// signature is also a plain P-256 signature over the SHA-256 of its signed data, which
    /// serves as the card vector.
    bytes32 constant QX = 0xd0684eb8b46d78bc5afa3d1528c881cd8dd2934ebdc68c90dc65b07a55a5afef;
    bytes32 constant QY = 0xdd9b7eec887febd32fa8dbccbc106601118a2f48f288b2b78043abe73fc6245a;
    bytes32 constant R = 0x76134b7b5356855b897b29aec54ca9f22ac84025a2a06bd241a5597bb13ff449;
    bytes32 constant S = 0x57340ef8dddef49d532d1f5a4ec0a4ffa5c00288fe66819d27470b8069c5a07b;
    bytes constant AUTH_DATA = hex"49960de5880e8c687434170f6476605b8fe4aeb9a28632c7995cf3ba831d97630500000002";
    string constant CLIENT_DATA =
        '{"type":"webauthn.get","challenge":"k9IYlWp_HAAmXuBwV_1Gtaad5WKnrSdwsDBCARkDVUg","origin":"http://localhost:8765","crossOrigin":false}';
    uint256 constant TYPE_INDEX = 1;
    uint256 constant CHALLENGE_INDEX = 23;
    string constant PASSKEY_DIGEST = "spike passkey digest";

    /// @dev The RSA-2048 partner key and signature from test/compat/Partners.t.sol, over the
    /// SHA-256 of sha256("spike partner digest").
    bytes constant RSA_E = hex"010001";
    bytes constant RSA_N =
        hex"8dfa31a9a25615403e48b49559d11682fd87ddbad0711e7920d598dcfb23191361bb2982dc9393fcc0a92d25b1c50256995a0633f21488a589e450360fbc4a93772ed8f9dc91cef287b938c694238a9dda1a87c9de47741b43f5d52969fb96680ff84f65f8779fbcaa3eac0ba0eecf579b564949a628c9fe6c112b9a7c430d3e9cf0b4cdd47862744aee3538513ebb5bd44e1a872aeedefd2200fa7e3019942a17bc2b1e9cccaf3463f34d6a9c82f6fd38561490876861952f6d02832428cfbb7bffb02e3b49412719e28b9139a11742f9bae42c202d3c7c768490bf679d31d166c3016d4b704f7062062210ae638997592f9cb4661fe4066103e1629f05a91f";
    bytes constant RSA_SIG =
        hex"8003546d55c61493df39b0d0825cbfa44a7f6381c38afba29e90e5be80857ec73d021b4df64e7de6bbcb8ddffb7eb2de14f3e9c9e84ae6c04343bb1ea125ced47495c507a168c57b41798a478b3361b057203ca5bc36d8dbf59748f608105c213b7bbe0944354f8431c5a250df81d18ee49fbe01ecf05ea39f34af4f9bfc4e0930ebaf47a9f3f66cb2c27d2daf7711e932afc044835d31dc18aeda28a3b1c6633e81c7f95c143749bc8d8384c450d92d8e8ab1626c25b26be67ad22454db91d68250942ecf0fdb6d8d00998e05dd907dbf7f17d3a7f6bbc1e257e0a730212ad4885edba121e072c048ed6b74428136023e8184f22e3a7e29294c67ad4d2f85b5";
    string constant PARTNER_DIGEST = "spike partner digest";

    error Misjudged(string check);

    /// @dev Called with empty calldata, so the script needs no ABI encoder. Returns
    /// abi.encode(bool precompile, uint256 precompileGas, uint256 cardGas, uint256 passkeyGas, uint256 rsaGas).
    fallback(bytes calldata) external returns (bytes memory) {
        bytes memory key = abi.encodePacked(QX, QY);
        bytes32 signed = sha256(abi.encodePacked(AUTH_DATA, sha256(bytes(CLIENT_DATA))));
        bytes32 challenge = sha256(bytes(PASSKEY_DIGEST));
        bytes memory assertion = abi.encode(R, S, CHALLENGE_INDEX, TYPE_INDEX, AUTH_DATA, CLIENT_DATA);

        (bool precompile, uint256 precompileGas) = _precompile(signed);
        (bool tampered, ) = _precompile(~signed);
        if (tampered) revert Misjudged("precompile");

        // Created in the call, so each verifier is already warm when first called and its figure is
        // about 2,500 gas below a deployed one's. The figures are for comparing chains, not absolute.
        IERC7913SignatureVerifier card = new ERC7913P256Verifier();
        IERC7913SignatureVerifier passkey = new ERC7913WebAuthnVerifier();
        uint256 cardGas = _check(card, key, signed, abi.encodePacked(R, S), "card");
        uint256 passkeyGas = _check(passkey, key, challenge, assertion, "passkey");
        IERC7913SignatureVerifier rsa = new ERC7913RSAVerifier();
        uint256 rsaGas = _check(rsa, abi.encode(RSA_E, RSA_N), sha256(bytes(PARTNER_DIGEST)), RSA_SIG, "rsa");

        return abi.encode(precompile, precompileGas, cardGas, passkeyGas, rsaGas);
    }

    /// @dev True only if the precompile answered and accepted; an address without it answers nothing.
    function _precompile(bytes32 hash) private view returns (bool ok, uint256 gasUsed) {
        uint256 before = gasleft();
        (bool success, bytes memory result) = P256_VERIFY.staticcall(abi.encodePacked(hash, R, S, QX, QY));
        gasUsed = before - gasleft();
        ok = success && result.length == 32 && abi.decode(result, (uint256)) == 1;
    }

    /// @dev Costs one accepted check, and confirms the same signature is refused for another hash.
    function _check(
        IERC7913SignatureVerifier verifier,
        bytes memory key,
        bytes32 hash,
        bytes memory signature,
        string memory name
    ) private view returns (uint256 gasUsed) {
        uint256 before = gasleft();
        bytes4 accepted = verifier.verify(key, hash, signature);
        gasUsed = before - gasleft();
        if (accepted != IERC7913SignatureVerifier.verify.selector) revert Misjudged(name);
        if (verifier.verify(key, ~hash, signature) == IERC7913SignatureVerifier.verify.selector) revert Misjudged(name);
    }
}
