// What the dashboard makes of the run's timeline: a plain sentence per line, the rule behind each refusal,
// what is still waiting, and the money each line moved for the bank map. The timeline comes from the
// control service; see docs/plan.md open question 23 and docs/architecture.md#story-lines.

import { hkd } from './money'

export { hkd }

export interface ChainEvent {
  contract: string
  address: string
  name: string
  args: Record<string, unknown>
}

export interface Line {
  seq: number
  time: string
  block: string
  kind: 'allowed' | 'refused' | 'operator'
  actor: string
  channel: string
  action: string
  signers?: string[]
  role?: string
  tx?: string
  reason?: { error: string; args: unknown[] }
  events: ChainEvent[]
}

export interface Deployment {
  chainId: number
  contracts: Record<string, string>
  customers: Record<string, string>
  staff: Record<string, string>
  cash: Record<string, string>
  presets: { name: string; kind: 'routine' | 'adverse'; group?: string; control?: string }[]
  groups: string[]
  beats: { number: number; title: string; pointAt: string; claim: string }[]
}

// The general ledger accounts a line's entry moved, by their number in GeneralLedger.Account.
export function accountsMoved(line: Line): number[] {
  return line.events
    .filter((e) => e.name === 'EntryPosted')
    .flatMap((e) => (e.args.lines as { account: number | string }[]).map((l) => Number(l.account)))
}

// What the adverse view marks: a refusal, a figure or count that did not match the ledger, or an incident.
export function isAlarm(line: Line): boolean {
  return line.kind === 'refused' || line.events.some((e) => e.name === 'IncidentReported' || e.args.matched === false)
}

// The rule behind each refusal, in plain words, by the contract error that names it.
const reasons: Record<string, string> = {
  NotTeller: 'they hold no teller role at this branch',
  NotApprover: 'it is not theirs to approve',
  TellerCannotApprove: 'a teller cannot approve their own operation',
  AlreadyApproved: 'they have already approved it',
  RecoveredTheAccount: 'they recovered this customer’s account, so may not act for them',
  DailyLimitExceeded: 'over the daily limit',
  ERC20InsufficientUnfrozenBalance: 'that money is frozen',
  ERC20InsufficientBalance: 'there is not enough money in the account',
  ERC20UserRestricted: 'the account is not a customer of the bank',
  InvalidAccountNonce: 'that authorisation has already been used',
  AuthorisedForAnotherIntent: 'the customer authorised something else',
  InvalidPartnerSignature: 'it is not signed with the clearing system’s registered key',
  ReferenceUsed: 'that payment reference has been used before',
  UnknownPayment: 'there is no such payment waiting',
  AccessManagedUnauthorized: 'their role does not allow it',
  InvalidExecutionSignature: 'it is not signed by a device on the account',
  DrawerLimit: 'the drawer would go over its limit',
  InsufficientCash: 'there is not enough cash there',
  BlockedCustomer: 'the customer is blocked',
  NotSupervisor: 'it needs a supervisor of the branch',
  NotCustodian: 'it needs the branch’s vault custodian',
  ApproverIsMaker: 'the approver must be someone else',
  ApproverIsOfficer: 'the approver must be someone else',
  AlreadyActed: 'each step needs a different person',
  DispenseInProgress: 'a dispense is still in progress',
  DispenseTimedOut: 'the dispense timed out',
}

export function reasonOf(line: Line): string {
  const error = line.reason?.error ?? 'Unknown'
  return reasons[error] ?? error.replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase()
}

// Head office's functions are named as functions; people and machines with "the".
const functions = new Set(['compliance', 'finance', 'risk', 'support', 'back office', 'IT security', 'anyone', 'operator'])

function who(actor: string): string {
  if (functions.has(actor)) return actor.charAt(0).toUpperCase() + actor.slice(1)
  if (actor === 'ATM') return 'The ATM'
  return /^[A-Z]/.test(actor) ? actor : `The ${actor}`
}

// One plain sentence per line: who did what, or what they attempted and the rule that stopped it.
export function sentence(line: Line): string {
  const actor = who(line.actor)
  if (line.kind === 'operator') return `Operator: ${line.action}.`
  if (line.kind === 'refused') return `Refused: ${actor} tried to ${line.action}, but ${reasonOf(line)}.`
  return `${actor}: ${line.action}.`
}

// Names for the addresses the dashboard knows: customers, staff and the bank's contracts.
export function namer(d: Deployment): (address: string) => string {
  const names = new Map<string, string>()
  for (const [n, a] of Object.entries(d.customers)) names.set(a.toLowerCase(), n)
  for (const [n, a] of Object.entries(d.staff)) names.set(a.toLowerCase(), `the ${n}`)
  for (const [n, a] of Object.entries(d.contracts)) names.set(a.toLowerCase(), `the ${n} module`)
  return (address) => names.get(String(address).toLowerCase()) ?? `${String(address).slice(0, 8)}…`
}

export interface Waiting {
  key: string
  what: string
  since: number
}

const approvers = ['a supervisor', 'the branch manager', 'compliance']

// Everything started and not yet finished, worked out from the timeline's events.
export function waiting(lines: Line[], name: (address: string) => string): Waiting[] {
  const open = new Map<string, Waiting>()
  const add = (key: string, what: string, since: number) => open.set(key, { key, what, since })
  for (const line of lines) {
    for (const e of line.events) {
      const a = e.args
      // A cash order's banking carries the ledger entry's reference beside the order's id; the order is
      // what was waiting.
      const ref = String(e.name === 'CashBanked' ? a.id : (a.ref ?? a.id ?? ''))
      const k = `${e.contract}:${ref}`
      const money = hkd(a.amount as string | undefined)
      switch (e.name) {
        case 'OperationOpened':
          if (Number(a.required) > 0) add(k, `${name(String(a.customer))}’s ${money} at the branch, waiting for ${approvers[0]}`, line.seq)
          break
        case 'OperationApproved': {
          const n = Number(a.approved)
          const item = open.get(k)
          if (item) item.what = item.what.replace(/waiting for .*$/, `waiting for ${approvers[n] ?? 'the last approver'}`)
          break
        }
        case 'WithdrawalHeld':
          add(k, `${name(String(a.customer))}’s ${money} at the ATM, waiting for the dispense`, line.seq)
          break
        case 'CreditReceived':
          if (Number(a.status) === 2) add(k, `${money} for ${name(String(a.beneficiary))}, waiting for compliance`, line.seq)
          if (Number(a.status) === 3) add(k, `${money} in suspense, for no account of the bank's`, line.seq)
          break
        case 'PaymentOrdered':
          add(k, `${name(String(a.payer))}’s payment of ${money}, ${Number(a.status) === 2 ? 'waiting for compliance' : 'queued to leave'}`, line.seq)
          break
        case 'PaymentQueued': {
          const item = open.get(k)
          if (item) item.what = item.what.replace('waiting for compliance', 'queued to leave')
          break
        }
        case 'Placed':
          add(`HoldRegister:${a.id}`, `a hold of ${money} on ${name(String(a.account))}: ${a.reason}`, line.seq)
          break
        case 'RecoveryProposed':
          add(k, `the recovery of ${name(String(a.account))}’s account, waiting for a supervisor`, line.seq)
          break
        case 'OrderProposed':
          add(k, `a cash order, waiting for a supervisor`, line.seq)
          break
        case 'DisputeOpened':
          add(k, `${name(String(a.customer))}’s dispute of ${money}, waiting for back office and compliance`, line.seq)
          break
        case 'ReversalProposed': {
          const item = open.get(k)
          if (item) item.what = item.what.replace('waiting for back office and compliance', 'waiting for compliance')
          break
        }
        case 'OperationCarriedOut':
        case 'OperationRefused':
        case 'OperationCancelled':
        case 'WithdrawalDispensed':
        case 'WithdrawalReturned':
        case 'IncomingCleared':
        case 'IncomingReturned':
        case 'PaymentSent':
        case 'PaymentReturned':
        case 'AccountRecovered':
        case 'RecoveryCancelled':
        case 'CashMoved':
        case 'CashBanked':
        case 'CashCounted':
        case 'OrderCancelled':
        case 'DisputeReversed':
        case 'DisputeRejected':
          open.delete(k)
          break
        case 'Lifted':
          open.delete(`HoldRegister:${a.id}`)
          break
      }
    }
  }
  return [...open.values()]
}

// The token movements a line made, for the bank map's vans: who paid whom, and how much.
export interface Movement {
  from: string
  to: string
  amount: bigint
  channel: string
}

export function movements(line: Line): Movement[] {
  if (line.kind !== 'allowed') return []
  return line.events
    .filter((e) => e.contract === 'DepositToken' && e.name === 'Transfer')
    .map((e) => ({ from: String(e.args.from), to: String(e.args.to), amount: BigInt(String(e.args.value)), channel: line.channel }))
}
