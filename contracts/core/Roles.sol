// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev The access manager's role numbers, as in the roles table of docs/roles.md. Contracts,
/// tests and agent tools take them from here, so a role means the same everywhere.
library Roles {
    uint64 internal constant ADMIN = 0;
    uint64 internal constant GOVERNANCE = 1;
    uint64 internal constant RISK = 2;
    uint64 internal constant TREASURY = 3;
    uint64 internal constant FINANCE = 4;
    uint64 internal constant COMPLIANCE = 5;
    uint64 internal constant BACK_OFFICE = 6;
    uint64 internal constant SUPPORT = 7;
    uint64 internal constant CREDIT_OFFICER = 8;
    uint64 internal constant IT_SECURITY = 9;
    uint64 internal constant INTERNAL_AUDIT = 10;

    uint64 internal constant ATM = 20;
    uint64 internal constant SCHEDULER = 21;

    uint64 internal constant LEDGER = 30;
    uint64 internal constant BOOKKEEPER = 31;
    uint64 internal constant ENFORCER = 32;
    uint64 internal constant FREEZER = 33;
    uint64 internal constant ISSUER = 34;
    uint64 internal constant STAFF_ADMIN = 35;

    /// @dev Branch roles, numbered 100 × branch plus one of these.
    uint64 internal constant TELLER = 1;
    uint64 internal constant SUPERVISOR = 2;
    uint64 internal constant BRANCH_MANAGER = 3;
    uint64 internal constant VAULT_CUSTODIAN = 4;
    uint64 internal constant ACCOUNT_OPENING_OFFICER = 5;

    error InvalidBranchRole(uint64 branch, uint64 role);

    /// @dev Branches are numbered from 1, so a branch role never lands on a central role's number.
    function atBranch(uint64 branch, uint64 role) internal pure returns (uint64) {
        if (branch == 0 || role < TELLER || role > ACCOUNT_OPENING_OFFICER) revert InvalidBranchRole(branch, role);
        return 100 * branch + role;
    }

    function branchOf(uint64 role) internal pure returns (uint64) {
        return role / 100;
    }

    function isBranchRole(uint64 role) internal pure returns (bool) {
        return branchRole(role) != 0;
    }

    /// @dev Which of the five branch roles `role` is, such as TELLER, or 0 if it is not a branch role.
    function branchRole(uint64 role) internal pure returns (uint64) {
        uint64 inBranch = role % 100;
        return role >= 100 && inBranch >= TELLER && inBranch <= ACCOUNT_OPENING_OFFICER ? inBranch : 0;
    }

    /// @dev A role held by a person, as opposed to a machine or a contract.
    function isStaffRole(uint64 role) internal pure returns (bool) {
        return (role >= RISK && role <= INTERNAL_AUDIT) || isBranchRole(role);
    }

    /// @dev Whether one account may not hold both roles, as the separation of duties in docs/roles.md
    /// lists the pairs the staff roles module refuses.
    function conflicts(uint64 a, uint64 b) internal pure returns (bool) {
        return _conflictsOneWay(a, b) || _conflictsOneWay(b, a);
    }

    function _conflictsOneWay(uint64 a, uint64 b) private pure returns (bool) {
        if (a == TREASURY) return b == FINANCE;
        if (a == IT_SECURITY) return isBranchRole(b) || b == BACK_OFFICE || b == SUPPORT;
        if (a == INTERNAL_AUDIT) return isStaffRole(b) && b != INTERNAL_AUDIT;
        return false;
    }
}
