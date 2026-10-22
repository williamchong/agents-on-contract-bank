// What the bank map's buildings and people are, for the details shown when one is selected: the concept in
// plain words, what it can do, the story lines it took part in, and the contracts behind it with their
// source. See docs/architecture.md#bank-map.

import { Ledger, PaymentStatus } from '@bank/services/books'
import type { BankState } from '@bank/services/state'
import { hkd } from '~/lib/money'
import { accountsMoved, type Deployment, type Line } from '~/lib/story'
import { buildings, staffPosts, type BuildingId } from './layout'

export type EntityId = BuildingId | `staff:${string}` | `customer:${string}`

export const staffId = (name: string): EntityId => `staff:${name}`
export const customerId = (name: string): EntityId => `customer:${name}`

// Which kind of entity an id names, and the staff or customer name in it.
export function parse(id: EntityId): { kind: 'staff'; name: string } | { kind: 'customer'; name: string } | { kind: 'building'; id: BuildingId } {
  if (id.startsWith('staff:')) return { kind: 'staff', name: id.slice('staff:'.length) }
  if (id.startsWith('customer:')) return { kind: 'customer', name: id.slice('customer:'.length) }
  return { kind: 'building', id: id as BuildingId }
}

export interface Entity {
  id: EntityId
  kind: 'Building' | 'Staff' | 'Customer'
  title: string
  concept: string
  can: string[]
  // Keys of Deployment.contracts, or 'account' for the entity's own multi-signer account.
  contracts: string[]
}

const REPO = 'https://github.com/williamchong/agents-on-contract-bank/blob/master/contracts/core'
const OZ = 'https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.7.0/contracts'

const core = (name: string) => ({ name, url: `${REPO}/${name}.sol` })
const account = core('MultiSignerAccount')

// Each contract's source, by its key in the deployment.
export const sources: Record<string, { name: string; url: string }> = {
  token: core('DepositToken'),
  ledger: core('GeneralLedger'),
  staffRoles: core('StaffRoles'),
  holds: core('HoldRegister'),
  partnerKeys: core('PartnerKeys'),
  payments: core('Payments'),
  attestations: core('Attestations'),
  cash: core('CashOperations'),
  assisted: core('AssistedOperations'),
  recovery: core('AccountRecovery'),
  disputes: core('DisputeReversal'),
  incidents: core('IncidentLog'),
  limits: core('CustomerLimits'),
  officers: account,
  account,
  manager: { name: 'AccessManager', url: `${OZ}/access/manager/AccessManager.sol` },
  timelock: { name: 'TimelockController', url: `${OZ}/governance/TimelockController.sol` },
  verifier: { name: 'ERC7913P256Verifier', url: `${OZ}/utils/cryptography/verifiers/ERC7913P256Verifier.sol` },
}

// Block explorers by chain id; the local chain has none.
const explorers: Record<number, string> = { 84532: 'https://sepolia.basescan.org', 8453: 'https://basescan.org' }

export function explorer(chainId: number | undefined): string | undefined {
  return chainId === undefined ? undefined : explorers[chainId]
}

const buildingInfo: Record<BuildingId, Omit<Entity, 'id' | 'kind' | 'title'>> = {
  'head-office': {
    concept: 'The general ledger: the bank’s books, kept on chain. Every movement of money posts a balanced entry here, so the books cannot disagree with the money.',
    can: ['Post a balanced entry for every movement', 'Refuse any entry that does not balance', 'Report the balance sheet and its ratios'],
    contracts: ['ledger', 'token'],
  },
  'town-hall': {
    concept: 'Governance. High-risk changes, such as granting roles or changing limits, are signed by the bank’s officers and wait out a time lock before they take effect.',
    can: ['Grant and revoke staff roles', 'Schedule changes behind a time lock', 'Set who may call what'],
    contracts: ['manager', 'timelock', 'officers', 'staffRoles'],
  },
  'water-tower': {
    concept: 'The settlement account the bank holds at the clearing system. The water level is its balance: payments out drain it and payments in fill it.',
    can: ['Fund payments to other banks', 'Be checked against the clearing system’s statement'],
    contracts: ['ledger', 'attestations'],
  },
  branch: {
    concept: 'Where tellers serve customers at the counter. Large or paper-based operations wait here for a supervisor, then the branch manager or compliance, to approve them.',
    can: ['Take cash in and pay it out', 'Act on a customer’s card, device or paper slip', 'Hold an operation until its approvers sign'],
    contracts: ['assisted', 'cash', 'limits'],
  },
  vault: {
    concept: 'The branch’s cash. The vault custodian issues it to the tellers’ drawers and the ATM, counts it, and banks any surplus.',
    can: ['Move cash to drawers and the ATM', 'Count cash against the ledger', 'Bank surplus cash'],
    contracts: ['cash'],
  },
  atm: {
    concept: 'A cash machine. It pays out against the customer’s card authorisation and must confirm or report each dispense.',
    can: ['Pay out cash on a card authorisation', 'Report a failed dispense, which returns the money'],
    contracts: ['cash', 'account'],
  },
  custodian: {
    concept: 'Holds the bank’s liquid securities, the assets it can sell quickly to meet withdrawals.',
    can: ['Confirm holdings', 'Report yield'],
    contracts: ['ledger', 'attestations'],
  },
  'post-office': {
    concept: 'The payments module. Payments to and from other banks pass through here, queued until the settlement account covers them.',
    can: ['Order and queue payments out', 'Receive credit advices from the clearing system', 'Return a payment that cannot be applied'],
    contracts: ['payments'],
  },
  'compliance-yard': {
    concept: 'Payments flagged for review wait here until compliance clears or returns them.',
    can: ['Hold a flagged payment', 'Release it once compliance clears it'],
    contracts: ['payments', 'holds'],
  },
  'suspense-lot': {
    concept: 'Money that arrived for no account of the bank’s waits here until it is returned to the sender.',
    can: ['Park an unmatched payment', 'Return it to the sending bank'],
    contracts: ['payments'],
  },
  'clearing-house': {
    concept: 'Other banks, through the clearing system. Its messages are signed with registered keys, so a forged advice is refused.',
    can: ['Send credit advices', 'Carry payments out', 'Issue settlement statements'],
    contracts: ['partnerKeys', 'payments', 'attestations'],
  },
}

// What each member of staff does, from docs/roles.md.
const staffInfo: Record<string, { concept: string; can: string[] }> = {
  teller: { concept: 'Serves customers at the branch counter.', can: ['Take cash in and pay it out', 'Act on a customer’s instruction', 'Open operations for approval'] },
  'replacement teller': { concept: 'Takes over the counter when the branch grants them the teller role.', can: ['As the teller, once granted the role'] },
  supervisor: { concept: 'Approves the tellers’ operations, including every debit on a paper slip.', can: ['Approve teller operations', 'Approve account recoveries and cash orders'] },
  'branch manager': { concept: 'The further approver for large branch operations.', can: ['Approve large operations', 'Grant and revoke roles within the branch'] },
  'vault custodian': { concept: 'Keeps the branch’s cash under dual control.', can: ['Issue cash to drawers and the ATM', 'Count cash', 'Bank surplus cash'] },
  'account opening officer': { concept: 'Onboards customers and recovers accounts, with a second check.', can: ['Open accounts', 'Enrol a first device and card', 'Propose account recovery'] },
  compliance: { concept: 'Checks the business against the rules.', can: ['Clear flagged payments', 'Place and lift holds', 'Approve the largest operations'] },
  'back office': { concept: 'Handles exceptions after the counter.', can: ['Handle payment exceptions', 'Reverse disputed operations'] },
  finance: { concept: 'Reconciles the books against outside statements.', can: ['Reconcile the ledger with clearing and custodian statements', 'Record cash counts'] },
  risk: { concept: 'Watches for incidents.', can: ['Pause the system in an incident', 'Advise on limits'] },
  support: { concept: 'Helps customers who lose devices or dispute an operation.', can: ['Freeze accounts and revoke devices', 'Open disputes', 'Cannot pay out to others'] },
  'IT security': { concept: 'Looks after machines and keys.', can: ['Enrol and retire ATMs and terminals', 'Rotate compromised keys', 'Approve grants of branch roles'] },
  'red team': { concept: 'An attacker with a teller role at another branch, trying to exceed it or steal funds. Every attempt should be refused.', can: ['Try anything; the chain decides'] },
}

export function entity(id: EntityId): Entity | undefined {
  const p = parse(id)
  if (p.kind === 'staff') {
    const info = staffInfo[p.name]
    return info && { id, kind: 'Staff', title: p.name.charAt(0).toUpperCase() + p.name.slice(1), ...info, contracts: ['account', 'staffRoles'] }
  }
  if (p.kind === 'customer') {
    const name = p.name
    return {
      id,
      kind: 'Customer',
      title: name,
      concept: `A retail customer. ${name}’s money is deposit tokens in an account they sign for with their own devices and card; the house grows with the balance.`,
      can: ['Pay from their phone', 'Withdraw at the ATM with their card', 'Instruct a teller, on their card or a paper slip', 'Recover the account if every device is lost'],
      contracts: ['account', 'token', 'limits'],
    }
  }
  const b = buildings.find((x) => x.id === p.id)
  return b && { id, kind: 'Building', title: b.label, ...buildingInfo[b.id] }
}

// The address an entity's 'account' contract stands for: its own multi-signer account. The ATM signs as
// staff but is a building on the map.
export function accountOf(id: EntityId, d: Deployment): string | undefined {
  const p = parse(id)
  if (p.kind === 'staff') return d.staff[p.name]
  if (p.kind === 'customer') return d.customers[p.name]
  if (p.id === 'atm') return d.staff.ATM
  return undefined
}

// The contracts behind an entity or a check, by their keys in the deployment, with their source and address;
// 'account' is the entity's own account.
export function contractsOf(keys: string[], d: Deployment, id?: EntityId): { key: string; name: string; url: string; address?: string }[] {
  return keys.flatMap((key) => {
    const source = sources[key]
    if (!source) return []
    if (key !== 'account') return [{ key, ...source, address: d.contracts[key] }]
    return [{ key, name: `${source.name} (its own account)`, url: source.url, address: id && accountOf(id, d) }]
  })
}

// Staff present at each block: the replacement teller and the ATM only once granted a role, and anyone
// whose role was revoked gone.
export function staffPresent(d: Deployment, lines: Line[]): Set<string> {
  const present = new Set(Object.keys(d.staff).filter((n) => n !== 'replacement teller' && n !== 'ATM'))
  const byAccount = new Map(Object.entries(d.staff).map(([n, a]) => [a.toLowerCase(), n]))
  for (const line of lines) {
    for (const e of line.events) {
      const who = byAccount.get(String(e.args.account ?? '').toLowerCase())
      if (!who || e.contract !== 'StaffRoles') continue
      if (e.name === 'Granted') present.add(who)
      if (e.name === 'Revoked') present.delete(who)
    }
  }
  return present
}

// The staff who work at a building, as the map places them.
export function staffAt(id: BuildingId): string[] {
  return staffPosts.filter((p) => p.building === id).map((p) => p.name)
}

function mentions(line: Line, value: string | undefined): boolean {
  if (!value) return false
  const v = value.toLowerCase()
  return line.events.some((e) => Object.values(e.args).some((a) => String(a).toLowerCase() === v))
}

const moves = (line: Line, account: number) => accountsMoved(line).includes(account)

// Whether a story line concerns an entity, for its log.
export function concerns(id: EntityId, line: Line, d: Deployment): boolean {
  if (line.kind === 'operator') return false
  const p = parse(id)
  if (p.kind === 'staff') return line.actor === p.name
  if (p.kind === 'customer') return line.actor === p.name || mentions(line, d.customers[p.name])
  const on = (contract: string) => line.events.some((e) => e.contract === contract)
  switch (p.id) {
    case 'head-office':
      return on('GeneralLedger')
    case 'town-hall':
      return line.channel === 'admin' || on('StaffRoles') || on('AccessManager')
    case 'water-tower':
      return moves(line, Ledger.Settlement)
    case 'branch':
      return line.channel === 'branch' && line.actor !== 'vault custodian'
    case 'vault':
      return line.actor === 'vault custodian' || mentions(line, d.cash.vault)
    case 'atm':
      return line.channel === 'atm'
    case 'custodian':
      return moves(line, Ledger.Securities)
    case 'post-office':
      return on('Payments')
    case 'compliance-yard':
      return line.actor === 'compliance' || line.events.some((e) => e.contract === 'Payments' && Number(e.args.status) === PaymentStatus.Screening)
    case 'suspense-lot':
      return line.events.some((e) => e.name === 'CreditReceived' && Number(e.args.status) === PaymentStatus.Suspense)
    case 'clearing-house':
      return line.channel === 'partner'
  }
}

// What a building holds now, from the chain, as short figures.
export function figuresOf(id: EntityId, s: BankState | undefined): { label: string; value: string }[] {
  if (!s) return []
  const p = parse(id)
  if (p.kind === 'customer') {
    const c = s.customers.find((x) => x.name === p.name)
    return c ? [{ label: 'Balance', value: hkd(c.balance) }] : []
  }
  if (p.kind === 'staff') return []
  const drawers = s.cash.drawer + s.cash.replacementDrawer
  switch (p.id) {
    case 'head-office':
      return [
        { label: 'Books', value: s.booksBalance ? 'Balance' : 'Do not balance' },
        { label: 'Deposits', value: hkd(-s.ledger.Deposits) },
        { label: 'Equity', value: hkd(-s.ledger.Equity) },
      ]
    case 'water-tower':
      return [{ label: 'Settlement account', value: hkd(s.ledger.Settlement) }]
    case 'branch':
      return [
        { label: 'In the drawers', value: hkd(drawers) },
        { label: 'Awaiting approval', value: hkd(s.awaitingApproval) },
      ]
    case 'vault':
      return [{ label: 'Cash', value: hkd(s.cash.vault) }]
    case 'atm':
      return [{ label: 'Cash', value: hkd(s.cash.atm) }]
    case 'custodian':
      return [{ label: 'Liquid securities', value: hkd(s.ledger.Securities) }]
    case 'post-office':
      return [{ label: 'Payments waiting', value: hkd(s.inPayments) }]
  }
  return []
}
