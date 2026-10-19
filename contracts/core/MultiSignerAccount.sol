// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC7739} from "@openzeppelin/contracts/utils/cryptography/signers/draft-ERC7739.sol";
import {MultiSignerERC7913} from "@openzeppelin/contracts/utils/cryptography/signers/MultiSignerERC7913.sol";

/// @dev The key types an account accepts, fixed at deployment. A key is an ERC-7913 verifier
/// followed by the key; any other verifier could accept every signature, so it is refused, as are
/// plain Ethereum keys.
abstract contract KeyTypes {
    mapping(address verifier => bool) private _accepted;

    error KeyTypeRefused(bytes signer);

    constructor(address[] memory verifiers) {
        for (uint256 i = 0; i < verifiers.length; ++i) _accepted[verifiers[i]] = true;
    }

    function _checkKeyType(bytes memory signer) internal view {
        if (signer.length <= 20 || !_accepted[address(bytes20(signer))]) revert KeyTypeRefused(signer);
    }
}

/// @dev A party's account: signers with a threshold, of the key types fixed at deployment. Staff
/// and the governance officers act from one. Its own calls are an ERC-7821 batch its signers sign
/// with a one-use number, which the submission service relays; signer changes are calls to itself
/// in such a batch. A customer's account is deployed with the bank's recovery module fixed in it, the one
/// other contract that may change its signers, and only its signers. See docs/standards.md and open
/// question 21 in docs/plan.md. KeyTypes comes before MultiSignerERC7913 so the accepted verifiers are
/// set before the initial signers are checked.
contract MultiSignerAccount is Account, EIP712, ERC7739, ERC7821, KeyTypes, MultiSignerERC7913 {
    bytes32 private constant EXECUTE_TYPEHASH = keccak256("Execute(bytes executionData,uint256 nonce)");

    /// @dev The recovery module, or zero for an account no module may recover, such as staff's.
    address public immutable recovery;
    /// @dev The one-use number the next signed batch must carry.
    uint256 public executionNonce;

    error InvalidExecutionSignature();
    error NotRecovery(address caller);

    constructor(
        address[] memory verifiers,
        bytes[] memory signers,
        uint64 threshold_,
        address recovery_
    ) EIP712("MultiSignerAccount", "1") KeyTypes(verifiers) MultiSignerERC7913(signers, threshold_) {
        recovery = recovery_;
    }

    /// @dev Runs a batch of calls in ERC-7821's batch encoding, signed by enough of the signers.
    function executeSigned(bytes calldata executionData, bytes calldata signature) external {
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(EXECUTE_TYPEHASH, keccak256(executionData), executionNonce++)));
        if (!_rawSignatureValidation(hash, signature)) revert InvalidExecutionSignature();
        ERC7579Utils.execBatch(executionData, ERC7579Utils.EXECTYPE_DEFAULT);
    }

    function addSigners(bytes[] memory signers) public onlyEntryPointOrSelf {
        _addSigners(signers);
    }

    function removeSigners(bytes[] memory signers) public onlyEntryPointOrSelf {
        _removeSigners(signers);
    }

    /// @dev The recovery module removes signers and enrols new ones; it can do nothing else.
    function recoverSigners(bytes[] memory removed, bytes[] memory added) external {
        if (msg.sender != recovery) revert NotRecovery(msg.sender);
        // Enrolled first, so the threshold stays reachable when every lost signer is removed.
        if (added.length != 0) _addSigners(added);
        if (removed.length != 0) _removeSigners(removed);
    }

    function setThreshold(uint64 threshold_) public onlyEntryPointOrSelf {
        _setThreshold(threshold_);
    }

    function _addSigners(bytes[] memory signers) internal override {
        for (uint256 i = 0; i < signers.length; ++i) _checkKeyType(signers[i]);
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
