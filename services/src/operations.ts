// What each scripted actor can do, through its own account and the channel it acts from. AI agents get the
// same operations as tools at milestone 5; see docs/roles.md.

import { encodeAbiParameters, keccak256, numberToHex, pad, toBytes, zeroAddress, zeroHash, type Address, type Hex } from 'viem'
import { ref, type Bank } from './bank.ts'
import { atm, drawer, hkd, Holders, Ledger, LoanStatus, OrderStatus, percent, vault, type CustomerName, type Location } from './books.ts'
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

// The payee another customer of the bank is registered under: their address, as CustomerLimits.payeeOf has it.
export function customerPayee(bank: Bank, customer: CustomerName): Hex {
  return pad(bank.account(customer), { size: 32 })
}

export function registerCustomerAsPayee(bank: Bank, customer: CustomerName, payee: CustomerName): Promise<Outcome> {
  return bank.act(customer, 'app', `register ${payee} as a payee`, [
    bank.call('CustomerLimits', bank.contracts.limits, 'registerPayee', [customerPayee(bank, payee)]),
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

// The borrower accepts the loan's terms from their own device, which draws it through the lending guard. The
// same batch gives the loans module the mandate to take its instalments, on top of what it may already take
// for their other loans.
export async function acceptLoan(bank: Bank, customer: string, ref: Hex, amount: bigint): Promise<Outcome> {
  const { loans, token } = bank.contracts
  const account = bank.account(customer)
  const [loan, mandate] = await Promise.all([
    bank.read('Loans', loans, 'loan', [ref]),
    bank.read('DepositToken', token, 'allowance', [account, loans]),
  ])
  const instalment = await bank.read('Loans', loans, 'annuity', [loan.amount, loan.terms])
  const calls = [
    bank.call('DepositToken', token, 'approve', [loans, mandate + instalment * loan.terms.instalments]),
    bank.call('Loans', loans, 'accept', [ref]),
  ]
  return bank.act(customer, 'app', `accept a loan of ${hkd(amount)}`, calls, { attempt: { from: loans, to: account, amount } })
}

// The credit officer cancels a loan not yet drawn, such as one the lending guard refused.
export function cancelLoan(bank: Bank, ref: Hex): Promise<Outcome> {
  return bank.act('credit officer', 'lending office', `cancel loan ${ref.slice(0, 10)}`, [bank.call('Loans', bank.contracts.loans, 'cancel', [ref])])
}

// The customer cancels one loan's mandate, as they might stop a direct debit; their other loans stay covered.
export function cancelMandate(bank: Bank, customer: string, ref: Hex): Promise<Outcome> {
  return bank.act(customer, 'app', `cancel the mandate for loan ${ref.slice(0, 10)}`, [
    bank.call('Loans', bank.contracts.loans, 'cancelMandate', [ref]),
  ])
}

// The first `count` references a module numbered in turn, as keccak256(chain id, module, number).
function numberedRefs(bank: Bank, module: Address, count: bigint): Hex[] {
  return Array.from({ length: Number(count) }, (_, i) =>
    keccak256(encodeAbiParameters([{ type: 'uint256' }, { type: 'address' }, { type: 'uint256' }], [BigInt(bank.chain.chainId), module, BigInt(i + 1)])),
  )
}

// Every loan the module holds, by the reference Loans.propose gave each in turn.
export async function loanRefs(bank: Bank): Promise<Hex[]> {
  const { loans } = bank.contracts
  return numberedRefs(bank, loans, await bank.read('Loans', loans, 'loanCount', []))
}

// The scheduler triggers the collection of each drawn loan with an instalment come due since its last
// collection; the loans module works out what is due and takes it. A loan in arrears is tried again when
// its next instalment falls due, not each day, as a bank re-presents a direct debit on the next due date.
export async function collectInstalments(bank: Bank): Promise<Outcome[]> {
  const { loans } = bank.contracts
  const refs = await loanRefs(bank)
  const found = await Promise.all(
    refs.map(async (ref) => {
      const [loan, due] = await Promise.all([bank.read('Loans', loans, 'loan', [ref]), bank.read('Loans', loans, 'instalmentsDue', [ref])])
      return loan.status === LoanStatus.Drawn && due > loan.paid + loan.unpaid
    }),
  )
  const outcomes: Outcome[] = []
  for (const ref of refs.filter((_, i) => found[i])) {
    outcomes.push(await bank.act('scheduler', 'scheduler', `collect the instalments due on loan ${ref.slice(0, 10)}`, [bank.call('Loans', loans, 'collectDue', [ref])]))
  }
  return outcomes
}

// The customer pays into their savings from their own device: the vault takes the deposit tokens and issues
// shares, which grow in value as interest is paid. Moving money into one's own savings counts against no limit.
export function payIntoSavings(bank: Bank, customer: string, amount: bigint): Promise<Outcome> {
  const { savings, token } = bank.contracts
  const account = bank.account(customer)
  return bank.act(customer, 'app', `pay ${hkd(amount)} into savings`, [
    bank.call('DepositToken', token, 'approve', [savings, amount]),
    bank.call('Savings', savings, 'deposit', [amount, account]),
  ], { attempt: { from: account, to: savings, amount } })
}

export function withdrawSavings(bank: Bank, customer: string, amount: bigint): Promise<Outcome> {
  const { savings } = bank.contracts
  const account = bank.account(customer)
  return bank.act(customer, 'app', `withdraw ${hkd(amount)} from savings`, [bank.call('Savings', savings, 'withdraw', [amount, account, account])], {
    attempt: { from: savings, to: account, amount },
  })
}

export const DAY = 86_400n
// Hong Kong keeps eight hours ahead of UTC all year.
export const HK_OFFSET = 8n * 3600n

// The day block time `time` falls on, counted from the epoch in Hong Kong time, as the contracts count days.
export function hongKongDay(time: bigint): bigint {
  return (time + HK_OFFSET) / DAY
}

// Closing the business day pays its savings interest, and that of any day missed, into the vault. The vault
// works out the days and the amount; the scheduler is only told the day has not been closed yet.
export async function payInterest(bank: Bank): Promise<Outcome | undefined> {
  const { savings } = bank.contracts
  const [paid, now] = await Promise.all([bank.read('Savings', savings, 'lastPaidDay', []), bank.now()])
  if (BigInt(paid) >= hongKongDay(now)) return undefined
  return bank.act('scheduler', 'scheduler', 'pay the savings interest of the day', [bank.call('Savings', savings, 'payInterestDue', [])])
}

// Whom a standing order pays: another customer of the bank, or someone at another bank named as the story says it.
export type OrderPayee = { customer: CustomerName } | { elsewhere: string }

// The customer sets up a monthly standing order from their app, and allows the module what all their orders
// still to be paid will take.
export async function setUpStandingOrder(bank: Bank, customer: CustomerName, payee: OrderPayee, amount: bigint, payments: bigint): Promise<Outcome> {
  const { orders, token } = bank.contracts
  const [to, hash, name] = 'customer' in payee ? [bank.account(payee.customer), zeroHash, payee.customer] : [zeroAddress, payeeHash(payee.elsewhere), payee.elsewhere]
  const committed = await bank.read('StandingOrders', orders, 'committed', [bank.account(customer)])
  return bank.act(customer, 'app', `set up a standing order of ${hkd(amount)} a month to ${name}, ${payments} payments`, [
    bank.call('DepositToken', token, 'approve', [orders, committed + amount * payments]),
    bank.call('StandingOrders', orders, 'setUp', [to, hash, amount, payments]),
  ])
}

// Every standing order the module holds, by the reference StandingOrders.setUp gave each in turn.
export async function orderRefs(bank: Bank): Promise<Hex[]> {
  const { orders } = bank.contracts
  return numberedRefs(bank, orders, await bank.read('StandingOrders', orders, 'orderCount', []))
}

// The scheduler triggers each active standing order with a payment come due; the module works out what is
// due and pays it, or misses it.
export async function payStandingOrders(bank: Bank): Promise<Outcome[]> {
  const { orders } = bank.contracts
  const refs = await orderRefs(bank)
  const found = await Promise.all(
    refs.map(async (ref) => {
      const [order, due] = await Promise.all([bank.read('StandingOrders', orders, 'order', [ref]), bank.read('StandingOrders', orders, 'paymentsDue', [ref])])
      return order.status === OrderStatus.Active && due > order.tried
    }),
  )
  const outcomes: Outcome[] = []
  for (const ref of refs.filter((_, i) => found[i])) {
    outcomes.push(await bank.act('scheduler', 'scheduler', `pay standing order ${ref.slice(0, 10)}`, [bank.call('StandingOrders', orders, 'payDue', [ref])]))
  }
  return outcomes
}

// Treasury proposes new savings and loan rates under the hash of its pricing paper, for governance to apply.
export function proposeRates(bank: Bank, rates: { savingsBps: bigint; loanBps: bigint }, paper: Hex): Promise<Outcome> {
  return bank.act('treasury', 'head office', `propose a savings rate of ${percent(rates.savingsBps)} and a loan rate of ${percent(rates.loanBps)}`, [
    bank.call('Rates', bank.contracts.rates, 'proposeProductRates', [rates, paper]),
  ])
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
