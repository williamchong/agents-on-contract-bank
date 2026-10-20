// The access manager's role numbers, as contracts/core/Roles.sol and the roles table in docs/roles.md
// give them.

export const Roles = {
  ADMIN: 0n,
  GOVERNANCE: 1n,
  RISK: 2n,
  TREASURY: 3n,
  FINANCE: 4n,
  COMPLIANCE: 5n,
  BACK_OFFICE: 6n,
  SUPPORT: 7n,
  CREDIT_OFFICER: 8n,
  IT_SECURITY: 9n,
  INTERNAL_AUDIT: 10n,
  ATM: 20n,
  SCHEDULER: 21n,
  LEDGER: 30n,
  BOOKKEEPER: 31n,
  ENFORCER: 32n,
  FREEZER: 33n,
  ISSUER: 34n,
  STAFF_ADMIN: 35n,
  LIMIT_KEEPER: 36n,
  DISPUTE_HOLDER: 37n,
  PAYMENT_ORIGINATOR: 38n,
} as const

export const BranchRole = {
  TELLER: 1n,
  SUPERVISOR: 2n,
  BRANCH_MANAGER: 3n,
  VAULT_CUSTODIAN: 4n,
  ACCOUNT_OPENING_OFFICER: 5n,
} as const

export function atBranch(branch: bigint, role: bigint): bigint {
  return 100n * branch + role
}

const words = (o: Record<string, bigint>) => new Map(Object.entries(o).map(([k, v]) => [v, k.toLowerCase().replaceAll('_', ' ')]))
const roleWords = words(Roles)
const branchRoleWords = words(BranchRole)

// A role number in words, as the story's under-the-hood view shows it, such as "teller at branch 1".
export function roleName(role: bigint): string {
  if (role < 100n) return roleWords.get(role) ?? `role ${role}`
  return `${branchRoleWords.get(role % 100n) ?? `role ${role % 100n}`} at branch ${role / 100n}`
}
