// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SpikeCustomerAccount} from "./SpikeCustomerAccount.sol";

/// @dev Toolchain spike: the one module allowed to change a customer account's signers. Who may
/// call it is decided by the access manager; what it can do is limited to replacing a signer.
contract SpikeRecovery is AccessManaged {
    constructor(address manager) AccessManaged(manager) {}

    function replaceSigner(SpikeCustomerAccount account, bytes calldata lost, bytes calldata replacement) external restricted {
        bytes[] memory signers = new bytes[](1);
        signers[0] = replacement;
        account.addSigners(signers);
        signers[0] = lost;
        account.removeSigners(signers);
    }
}
