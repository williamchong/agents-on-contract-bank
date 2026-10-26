// What each scripted actor can do, through its own account and the channel it acts from. AI agents get the
// same operations as tools at milestone 5; see docs/roles.md.

import { keccak256, numberToHex, toBytes, zeroAddress, type Address, type Hex } from 'viem'
import { ref, type Bank } from './bank.ts'
import { atm, drawer, hkd, Holders, Ledger, vault, type CustomerName, type Location } from './books.ts'
import type { Outcome } from './submission.ts'

// Reads

export function balanceOf(bank: Bank, name: string): Promise<bigint> {
  return bank.read('DepositToken', bank.contracts.token, 'balanceOf', [bank.account(name)])
}

export function supply(bank: Bank): Promise<bigint> {
  return bank.read('DepositToken', bank.contracts.token, 'totalSupply', [])
}

// What every holder on the opening balance sheet holds together.
export async function customerTotal(bank: Bank): Promise<bigint> {
  const balances = await Promise.all(Holders.map((n) => balanceOf(bank, n)))
  return balances.reduce((a, b) => a + b, 0n)
}

export function ledgerBalance(bank: Bank, account: number): Promise<bigint> {
  return bank.read('GeneralLedger', bank.contracts.ledger, 'balanceOf', [account])
}

export async function booksBalance(bank: Bank): Promise<boolean> {
  const all = await bank.read('GeneralLedger', bank.contracts.ledger, 'balances', [])
  return all.reduce((a, b) => a + b, 0n) === 0n
}

export async function cashAt(bank: Bank, at: Location): Promise<bigint> {
  return bank.read('CashOperations', bank.contracts.cash, 'cashAt', [await locationId(bank, at)])
}

export function locationId(bank: Bank, at: Location): Promise<Hex> {
  return bank.read('CashOperations', bank.contracts.cash, 'locationId', [at])
}

// Branch 1's places, which hold all the cash in the demo.
export function places(bank: Bank) {
  return { vault: vault(), drawer: drawer(bank.account('teller')), atm: atm(bank.account('ATM')) }
}

// The cash module's split, which must always sum to the ledger's cash account. Every teller's drawer
// counts, the replacement teller's included.
export async function cashSplitMatchesLedger(bank: Bank): Promise<boolean> {
  const all = [...Object.values(places(bank)), drawer(bank.account('replacement teller'))]
  const amounts = await Promise.all(all.map((p) => cashAt(bank, p)))
  return amounts.reduce((a, b) => a + b, 0n) === (await ledgerBalance(bank, Ledger.Cash))
}

// Customers, from their own devices

export function transfer(bank: Bank, from: CustomerName, to: string, amount: bigint): Promise<Outcome> {
  return bank.act(from, 'app', `transfer ${hkd(amount)} to ${to}`, [bank.call('DepositToken', bank.contracts.token, 'transfer', [bank.account(to), amount])], {
    attempt: { from: bank.account(from), to: bank.account(to), amount },
  })
}

// The customer registers a payee from their phone; it counts as registered once the waiting period ends.
export function registerPayee(bank: Bank, customer: CustomerName, payee: string): Promise<Outcome> {
  return bank.act(customer, 'app', `register ${payee} as a payee`, [
    bank.call('CustomerLimits', bank.contracts.limits, 'registerPayee', [payeeHash(payee)]),
  ])
}

// A payment to someone at another bank, whom `payee` names as the story says it. The payee's details stay
// with the bank; the chain sees their hash.
export function payOut(bank: Bank, from: CustomerName, payee: string, amount: bigint): Promise<Outcome> {
  const c = bank.contracts
  return bank.act(
    from,
    'app',
    `pay ${hkd(amount)} to ${payee}`,
    [bank.call('DepositToken', c.token, 'approve', [c.payments, amount]), bank.call('Payments', c.payments, 'pay', [amount, payeeHash(payee)])],
    { attempt: { from: bank.account(from), to: c.payments, amount } },
  )
}

// The hash of a payee's details, which is all the chain keeps of them.
export function payeeHash(payee: string): Hex {
  return keccak256(toBytes(payee))
}

// What a customer's authorisation is for: the module that will hold the money, the purpose, the branch
// and who is paid. The module derives its one-use number's key from it, so a teller or an ATM cannot use
// the authorisation for anything else. A payment out names its payee's hash in its purpose.
export interface Intent {
  module: 'cash' | 'assisted'
  purpose: 'ATM_WITHDRAWAL' | 'COUNTER_WITHDRAWAL' | 'TRANSFER' | { payee: Hex }
  branch: bigint
  recipient: Address
}

function purposeOf(bank: Bank, module: Address, purpose: Intent['purpose']): Promise<Hex> {
  if (typeof purpose === 'object') return bank.read('AssistedOperations', module, 'paymentPurpose', [purpose.payee])
  if (purpose === 'TRANSFER') return bank.read('AssistedOperations', module, 'TRANSFER', [])
  return bank.read('CashOperations', module, purpose, [])
}

// The customer's card, after the PIN, or their phone authorises a transfer of `amount` into the module for
// `intent`, under the next one-use number for that intent; a teller or an ATM submits it.
export async function authorise(bank: Bank, customer: CustomerName, intent: Intent, amount: bigint, device: 'card' | 'phone' = 'card') {
  const c = bank.contracts
  const account = bank.account(customer)
  const module = c[intent.module]
  const purpose = await purposeOf(bank, module, intent.purpose)
  const key = await bank.read('CashOperations', module, 'intentKey', [purpose, intent.branch, intent.recipient])
  const next = await bank.read('DepositToken', c.token, 'nonces', [account, key])
  const nonce = numberToHex((key << 64n) | next, { size: 32 })
  const validBefore = (await bank.now()) + 3600n
  const signer = device === 'card' ? bank.cardOf(customer) : bank.party(customer).keys[0]!
  const signature = bank.signer.signForAccount(account, [signer], {
    domain: { name: 'Deposit HKD', version: '1', chainId: bank.chain.chainId, verifyingContract: c.token },
    types: {
      ReceiveWithAuthorization: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'validAfter', type: 'uint256' },
        { name: 'validBefore', type: 'uint256' },
        { name: 'nonce', type: 'bytes32' },
      ],
    },
    primaryType: 'ReceiveWithAuthorization',
    message: { from: account, to: module, value: amount, validAfter: 0n, validBefore, nonce },
  })
  return { customer: account, amount, validAfter: 0n, validBefore, nonce, signature }
}

export type CardAuthorisation = Awaited<ReturnType<typeof authorise>>

export async function withdrawAtAtm(bank: Bank, customer: CustomerName, amount: bigint, branch = 1n): Promise<Outcome> {
  const intent = { module: 'cash', purpose: 'ATM_WITHDRAWAL', branch, recipient: bank.account('ATM') } as const
  return submitAtmWithdrawal(bank, customer, await authorise(bank, customer, intent, amount), branch)
}

// The ATM submits a card authorisation it was given, which a replay attempt reuses.
export function submitAtmWithdrawal(bank: Bank, customer: CustomerName, card: CardAuthorisation, branch = 1n): Promise<Outcome> {
  const c = bank.contracts
  return bank.act('ATM', 'atm', `withdraw ${hkd(card.amount)} for ${customer} by card`, [bank.call('CashOperations', c.cash, 'withdrawAtAtm', [branch, card])], {
    attempt: { from: bank.account(customer), to: c.cash, amount: card.amount },
  })
}

// The ATM reports whether it dispensed the cash it was asked for.
export function reportDispense(bank: Bank, ref: Hex, dispensed: boolean): Promise<Outcome> {
  const c = bank.contracts
  return dispensed
    ? bank.act('ATM', 'atm', 'confirm the dispense', [bank.call('CashOperations', c.cash, 'confirmDispense', [ref])])
    : bank.act('ATM', 'atm', 'report a failed dispense', [bank.call('CashOperations', c.cash, 'reportFailure', [ref])])
}

// The branch

export function cashDeposit(bank: Bank, customer: CustomerName, amount: bigint, teller = 'teller', branch = 1n): Promise<Outcome> {
  return bank.act(
    teller,
    'branch',
    `take ${hkd(amount)} in cash for ${customer}`,
    [bank.call('CashOperations', bank.contracts.cash, 'deposit', [branch, bank.account(customer), amount])],
    { attempt: { from: zeroAddress, to: bank.account(customer), amount } },
  )
}

// The vault custodian records a move or a count, and a supervisor confirms it.
async function underDualControl(bank: Bank, action: string, call: ReturnType<Bank['call']>): Promise<Outcome> {
  const proposed = await bank.act('vault custodian', 'branch', `record: ${action}`, [call])
  if (!proposed.ok) return proposed
  const id = eventArg<bigint>(proposed, 'OrderProposed', 'id')
  return bank.act('supervisor', 'branch', `confirm: ${action}`, [bank.call('CashOperations', bank.contracts.cash, 'confirmOrder', [id])])
}

export function moveCash(bank: Bank, from: Location, to: Location, amount: bigint, action: string): Promise<Outcome> {
  return underDualControl(bank, action, bank.call('CashOperations', bank.contracts.cash, 'proposeMove', [from, to, amount]))
}

export function countCash(bank: Bank, at: Location, counted: bigint, what: string): Promise<Outcome> {
  return underDualControl(bank, `count ${what}`, bank.call('CashOperations', bank.contracts.cash, 'proposeCount', [at, counted]))
}

// A teller's transfer for a customer: on the customer's card at the counter, or on a signed paper slip,
// whose scan's hash is recorded. It waits for the approvers the branch approval ladder names.
export async function transferAtCounter(
  bank: Bank,
  customer: CustomerName,
  to: string,
  amount: bigint,
  by: { card: true } | { slip: string },
  teller = 'teller',
  branch = 1n,
): Promise<Outcome> {
  const c = bank.contracts
  const attempt = { from: bank.account(customer), to: c.assisted, amount }
  if ('card' in by) {
    const card = await authorise(bank, customer, { module: 'assisted', purpose: 'TRANSFER', branch, recipient: bank.account(to) }, amount)
    return bank.act(teller, 'branch', `transfer ${hkd(amount)} from ${customer} to ${to} on their card`, [
      bank.call('AssistedOperations', c.assisted, 'transfer', [branch, bank.account(to), card]),
    ], { attempt })
  }
  return bank.act(teller, 'branch', `transfer ${hkd(amount)} from ${customer} to ${to} on a paper slip`, [
    bank.call('AssistedOperations', c.assisted, 'transferOnPaper', [branch, bank.account(customer), bank.account(to), amount, slipHash(by.slip)]),
  ], { attempt })
}

// A teller's payment for a customer to someone at another bank, on the customer's card at the counter or
// on a signed paper slip. It waits for the approvers the branch approval ladder names, then reaches the
// payments module in the customer's name, so a payment that comes back goes back to them.
export async function payAtCounter(
  bank: Bank,
  customer: CustomerName,
  payee: string,
  amount: bigint,
  by: { card: true } | { slip: string },
  teller = 'teller',
  branch = 1n,
): Promise<Outcome> {
  const c = bank.contracts
  const hash = payeeHash(payee)
  const attempt = { from: bank.account(customer), to: c.assisted, amount }
  if ('card' in by) {
    const card = await authorise(bank, customer, { module: 'assisted', purpose: { payee: hash }, branch, recipient: c.payments }, amount)
    return bank.act(teller, 'branch', `pay ${hkd(amount)} from ${customer} to ${payee} on their card`, [
      bank.call('AssistedOperations', c.assisted, 'pay', [branch, hash, card]),
    ], { attempt })
  }
  return bank.act(teller, 'branch', `pay ${hkd(amount)} from ${customer} to ${payee} on a paper slip`, [
    bank.call('AssistedOperations', c.assisted, 'payOnPaper', [branch, bank.account(customer), hash, amount, slipHash(by.slip)]),
  ], { attempt })
}

export async function withdrawAtCounter(bank: Bank, customer: CustomerName, amount: bigint, slip: string, teller = 'teller', branch = 1n): Promise<Outcome> {
  const c = bank.contracts
  return bank.act(teller, 'branch', `pay out ${hkd(amount)} in cash to ${customer} on a paper slip`, [
    bank.call('CashOperations', c.cash, 'withdrawAtCounterOnPaper', [branch, bank.account(customer), amount, slipHash(slip)]),
  ], { attempt: { from: bank.account(customer), to: c.cash, amount } })
}

// The hash of a scanned slip, which is all the chain keeps of it.
export function slipHash(slip: string): Hex {
  return keccak256(toBytes(slip))
}

export function operationOf(bank: Bank, module: 'assisted' | 'cash', ref: Hex) {
  return bank.read('AssistedOperations', bank.contracts[module], 'operation', [ref])
}

// An approver on the ladder approves or refuses an operation waiting in `module`.
export function decide(bank: Bank, approver: string, module: 'assisted' | 'cash', ref: Hex, verdict: 'approve' | 'refuse'): Promise<Outcome> {
  const name = module === 'assisted' ? 'AssistedOperations' : 'CashOperations'
  return bank.act(approver, 'branch', `${verdict} operation ${ref.slice(0, 10)}`, [bank.call(name, bank.contracts[module], verdict, [ref])])
}

// The account opening officer, after checking the customer's identity in person, proposes replacing the
// lost devices and card with new ones; a supervisor approves it with `approveRecovery`.
export function proposeRecovery(bank: Bank, customer: CustomerName, lost: string[], replacements: string[], branch = 1n): Promise<Outcome> {
  const c = bank.contracts
  return bank.act('account opening officer', 'branch', `propose recovering ${customer}'s account`, [
    bank.call('AccountRecovery', c.recovery, 'propose', [
      bank.account(customer),
      branch,
      lost.map((k) => bank.signer.signerBytes(k)),
      replacements.map((k) => bank.signer.signerBytes(k)),
      keccak256(toBytes(`identity check of ${customer} at branch ${branch}`)),
    ]),
  ])
}

export function approveRecovery(bank: Bank, proposed: Outcome): Promise<Outcome> {
  const id = eventArg<bigint>(proposed, 'RecoveryProposed', 'id')
  return bank.act('supervisor', 'branch', `approve recovery ${id}`, [bank.call('AccountRecovery', bank.contracts.recovery, 'approve', [id])])
}

// Support opens a dispute for a customer, which freezes the recipient's money at once; back office proposes
// the reversal and compliance approves it.
export function openDispute(bank: Bank, customer: CustomerName, recipient: string, amount: bigint, operation: Hex): Promise<Outcome> {
  return bank.act('support', 'support', `open ${customer}'s dispute of a transfer to ${recipient}`, [
    bank.call('DisputeReversal', bank.contracts.disputes, 'open', [bank.account(customer), bank.account(recipient), amount, operation]),
  ])
}

export function proposeReversal(bank: Bank, id: bigint): Promise<Outcome> {
  return bank.act('back office', 'head office', `propose reversing dispute ${id}`, [bank.call('DisputeReversal', bank.contracts.disputes, 'propose', [id])])
}

export function approveReversal(bank: Bank, id: bigint): Promise<Outcome> {
  return bank.act('compliance', 'head office', `approve reversing dispute ${id}`, [bank.call('DisputeReversal', bank.contracts.disputes, 'approve', [id])])
}

// Head office

export function compliance(
  bank: Bank,
  functionName: 'clearIncoming' | 'returnIncoming' | 'clearOutgoing' | 'returnOutgoing',
  ref: Hex,
  action: string,
): Promise<Outcome> {
  return bank.act('compliance', 'head office', action, [bank.call('Payments', bank.contracts.payments, functionName, [ref])])
}

export type IncidentKind = 'statement mismatch' | 'cash count mismatch'

// Finance reports an incident concerning `subject` to the regulator and records it, with the report's hash.
export function reportIncident(bank: Bank, kind: IncidentKind, subject: Hex, report: string): Promise<Outcome> {
  return bank.act('finance', 'head office', `report an incident to the regulator: ${kind}`, [
    bank.call('IncidentLog', bank.contracts.incidents, 'report', [ref(kind), subject, keccak256(toBytes(report))]),
  ])
}

// Anyone may release payments waiting in the queue: the release chooses nothing.
export function releasePayments(bank: Bank, max = 50n): Promise<Outcome> {
  return bank.act('back office', 'head office', 'release queued payments', [bank.call('Payments', bank.contracts.payments, 'release', [max])])
}

// Lending

// The credit officer proposes a loan of `amount` to `customer`, for a supervisor of branch 1 to approve.
export function proposeLoan(bank: Bank, customer: string, amount: bigint): Promise<Outcome> {
  return bank.act('credit officer', 'lending office', `propose a loan of ${hkd(amount)} to ${customer}`, [
    bank.call('Loans', bank.contracts.loans, 'propose', [bank.account(customer), 1n, amount]),
  ])
}

// A supervisor approves or refuses a proposed loan.
export function decideLoan(bank: Bank, ref: Hex, verdict: 'approve' | 'refuse'): Promise<Outcome> {
  return bank.act('supervisor', 'branch', `${verdict} loan ${ref.slice(0, 10)}`, [bank.call('Loans', bank.contracts.loans, verdict, [ref])])
}

// The borrower accepts the loan's terms from their own device, which draws it through the lending guard.
export function acceptLoan(bank: Bank, customer: string, ref: Hex, amount: bigint): Promise<Outcome> {
  return bank.act(customer, 'app', `accept a loan of ${hkd(amount)}`, [bank.call('Loans', bank.contracts.loans, 'accept', [ref])], {
    attempt: { from: bank.contracts.loans, to: bank.account(customer), amount },
  })
}

// The credit officer cancels a loan not yet drawn, such as one the lending guard refused.
export function cancelLoan(bank: Bank, ref: Hex): Promise<Outcome> {
  return bank.act('credit officer', 'lending office', `cancel loan ${ref.slice(0, 10)}`, [bank.call('Loans', bank.contracts.loans, 'cancel', [ref])])
}

// A loan from proposal to the customer's acceptance; the outcome is the acceptance, or the first step refused.
export async function lend(bank: Bank, customer: string, amount: bigint): Promise<{ ref?: Hex; outcome: Outcome }> {
  const proposed = await proposeLoan(bank, customer, amount)
  if (!proposed.ok) return { outcome: proposed }
  const ref = eventArg<Hex>(proposed, 'LoanProposed', 'ref')
  const approved = await decideLoan(bank, ref, 'approve')
  if (!approved.ok) return { ref, outcome: approved }
  return { ref, outcome: await acceptLoan(bank, customer, ref, amount) }
}

// Outcomes

export function emitted(outcome: Outcome, event: string): boolean {
  return outcome.ok && outcome.events.some((e) => e.name === event)
}

export function eventArg<T>(outcome: Outcome, event: string, arg: string): T {
  if (!outcome.ok) throw new Error(`Expected ${event}, but ${outcome.line.action} was refused: ${outcome.error}`)
  const found = outcome.events.find((e) => e.name === event)
  if (!found) throw new Error(`Expected ${event} in ${outcome.line.action}`)
  return found.args[arg] as T
}
