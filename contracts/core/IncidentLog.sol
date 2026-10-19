// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";

/// @dev The bank's incident log: what finance or risk reported to the regulator, such as a statement or a
/// cash count that did not match the ledger. Each entry names the kind of incident, what it concerns and
/// the hash of the report sent, which stays with the bank and the regulator; the chain keeps that it was
/// reported, by whom and when. The regulator reads the log. See open question 22 in docs/plan.md.
contract IncidentLog is AccessManaged {
    uint256 public incidentCount;

    event IncidentReported(uint256 indexed id, bytes32 indexed kind, bytes32 indexed subject, bytes32 reportHash, address reporter);

    error NoReport();

    constructor(address manager) AccessManaged(manager) {}

    /// @dev Records an incident of `kind` concerning `subject`, whose report to the regulator hashes to
    /// `reportHash`.
    function report(bytes32 kind, bytes32 subject, bytes32 reportHash) external restricted returns (uint256 id) {
        if (reportHash == 0) revert NoReport();
        id = ++incidentCount;
        emit IncidentReported(id, kind, subject, reportHash, msg.sender);
    }
}
