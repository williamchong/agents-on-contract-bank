// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC7739} from "@openzeppelin/contracts/utils/cryptography/signers/draft-ERC7739.sol";
import {MultiSignerERC7913} from "@openzeppelin/contracts/utils/cryptography/signers/MultiSignerERC7913.sol";

/// @dev Toolchain spike: a customer account whose devices are signers with a threshold. Signer
/// changes are open to the account itself and to one recovery module fixed at deployment, and the
/// module is given nothing else. Answers open question 7 without forking the library.
contract SpikeCustomerAccount is Account, EIP712, ERC7739, ERC7821, MultiSignerERC7913 {
    address public immutable recovery;

    modifier onlySelfOrRecovery() {
        if (msg.sender != recovery) _checkEntryPointOrSelf();
        _;
    }

    constructor(
        address recovery_,
        bytes[] memory signers,
        uint64 threshold_
    ) EIP712("SpikeCustomerAccount", "1") MultiSignerERC7913(signers, threshold_) {
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

    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32 mode,
        bytes calldata executionData
    ) internal view override returns (bool) {
        return caller == address(entryPoint()) || super._erc7821AuthorizedExecutor(caller, mode, executionData);
    }
}
