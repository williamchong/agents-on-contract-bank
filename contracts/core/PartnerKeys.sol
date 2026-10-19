// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @dev The partners whose keys the register holds, by the identifier their keys are registered under.
library Partners {
    bytes32 internal constant CLEARING = keccak256("clearing");
    bytes32 internal constant CUSTODIAN = keccak256("custodian");
}

/// @dev The register of partners' signing keys, which the payments module and the attested
/// figures check against. Each key is kept in ERC-7913 form, a verifier's address followed by the
/// key, so a partner signing with P-256 or RSA is registered the same way and no partner needs an
/// account on the chain. Plain Ethereum keys are refused: no clearing system holds one. Governance
/// registers and replaces a key, and IT security revokes a compromised one at once. Any verifier
/// with code is accepted, since only governance can name one. See open question 12 in docs/plan.md
/// and the partner key rows of the permission matrix in docs/roles.md.
contract PartnerKeys is AccessManaged {
    mapping(bytes32 partner => bytes signer) private _keys;

    event KeySet(bytes32 indexed partner, bytes signer);
    event KeyRevoked(bytes32 indexed partner);

    error NotAVerifierKey(bytes signer);

    constructor(address manager) AccessManaged(manager) {}

    function keyOf(bytes32 partner) external view returns (bytes memory) {
        return _keys[partner];
    }

    /// @dev Registers or replaces a partner's key; a replaced key is refused from then on. A
    /// verifier with no code would make every check fail and lock the partner out unseen.
    function setKey(bytes32 partner, bytes calldata signer) external restricted {
        if (signer.length <= 20 || address(bytes20(signer[:20])).code.length == 0) revert NotAVerifierKey(signer);
        _keys[partner] = signer;
        emit KeySet(partner, signer);
    }

    /// @dev For a compromised key: takes effect at once, with no waiting period. The partner's
    /// messages are refused until governance registers a new key.
    function revokeKey(bytes32 partner) external restricted {
        delete _keys[partner];
        emit KeyRevoked(partner);
    }

    function verify(bytes32 partner, bytes32 digest, bytes calldata signature) external view returns (bool) {
        bytes memory signer = _keys[partner];
        return signer.length != 0 && SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }
}
