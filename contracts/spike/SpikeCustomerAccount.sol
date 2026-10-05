// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC7739} from "@openzeppelin/contracts/utils/cryptography/signers/draft-ERC7739.sol";
import {MultiSignerERC7913} from "@openzeppelin/contracts/utils/cryptography/signers/MultiSignerERC7913.sol";

/// @dev Toolchain spike: the key types a customer device may have, fixed at deployment. A phone's
/// passkey is checked by a WebAuthn verifier and a chip card's key by a P-256 verifier. Any other
/// verifier could accept every signature, so it is refused, as are plain Ethereum keys.
abstract contract SpikeDeviceKeys {
    address public immutable passkeyVerifier;
    address public immutable cardVerifier;

    error NotADeviceKey(bytes signer);

    constructor(address passkeyVerifier_, address cardVerifier_) {
        passkeyVerifier = passkeyVerifier_;
        cardVerifier = cardVerifier_;
    }

    /// @dev Both verifiers take a 64-byte P-256 key after their address.
    function _checkDeviceKey(bytes memory signer) internal view {
        if (signer.length != 84) revert NotADeviceKey(signer);
        address verifier = address(bytes20(signer));
        if (verifier != passkeyVerifier && verifier != cardVerifier) revert NotADeviceKey(signer);
    }
}

/// @dev Toolchain spike: a customer account whose devices are signers with a threshold. Signer
/// changes are open to the account itself and to one recovery module fixed at deployment, and the
/// module is given nothing else. Answers open question 7 without forking the library.
/// SpikeDeviceKeys comes before MultiSignerERC7913 so its verifiers are set before the initial
/// signers are checked.
contract SpikeCustomerAccount is Account, EIP712, ERC7739, ERC7821, SpikeDeviceKeys, MultiSignerERC7913 {
    address public immutable recovery;

    modifier onlySelfOrRecovery() {
        if (msg.sender != recovery) _checkEntryPointOrSelf();
        _;
    }

    constructor(
        address recovery_,
        address passkeyVerifier_,
        address cardVerifier_,
        bytes[] memory signers,
        uint64 threshold_
    )
        EIP712("SpikeCustomerAccount", "1")
        SpikeDeviceKeys(passkeyVerifier_, cardVerifier_)
        MultiSignerERC7913(signers, threshold_)
    {
        recovery = recovery_;
    }

    function addSigners(bytes[] memory signers) public onlySelfOrRecovery {
        _addSigners(signers);
    }

    function removeSigners(bytes[] memory signers) public onlySelfOrRecovery {
        _removeSigners(signers);
    }

    function setThreshold(uint64 threshold_) public onlySelfOrRecovery {
        _setThreshold(threshold_);
    }

    function _addSigners(bytes[] memory signers) internal override {
        for (uint256 i = 0; i < signers.length; ++i) _checkDeviceKey(signers[i]);
        super._addSigners(signers);
    }

    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32 mode,
        bytes calldata executionData
    ) internal view override returns (bool) {
        return caller == address(entryPoint()) || super._erc7821AuthorizedExecutor(caller, mode, executionData);
    }
}
