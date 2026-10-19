// What each scripted actor can do, through its own account and the channel it acts from. AI agents get the
// same operations as tools at milestone 5; see docs/roles.md.

import { keccak256, numberToHex, toBytes, type Hex } from 'viem'
import type { Bank } from './bank.ts'
import { atm, drawer, Holders, Ledger, vault, type CustomerName, type Location } from './books.ts'
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
  return bank.act(from, 'app', `transfer ${amount} to ${to}`, [
    bank.call('DepositToken', bank.contracts.token, 'transfer', [bank.account(to), amount]),
  ])
}

// A payment to someone at another bank. The payee's details stay with the bank; the chain sees their hash.
export function payOut(bank: Bank, from: CustomerName, payee: string, amount: bigint): Promise<Outcome> {
  const c = bank.contracts
  return bank.act(from, 'app', `pay ${amount} to ${payee} at another bank`, [
    bank.call('DepositToken', c.token, 'approve', [c.payments, amount]),
    bank.call('Payments', c.payments, 'pay', [amount, keccak256(toBytes(payee))]),
  ])
}

// The customer's card, after the PIN, authorises a transfer to the cash module, and the ATM submits it.
export async function withdrawAtAtm(bank: Bank, customer: CustomerName, amount: bigint, branch = 1n): Promise<Outcome> {
  const c = bank.contracts
  const account = bank.account(customer)
  // The card's authorisations use their own key in the token's keyed one-use numbers.
  const cardKey = 1n
  const next = await bank.read('DepositToken', c.token, 'nonces', [account, cardKey])
  const nonce = numberToHex((cardKey << 64n) | next, { size: 32 })
  const validBefore = (await bank.now()) + 3600n
  const signature = bank.signer.signForAccount(account, [`${customer}:card`], {
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
    message: { from: account, to: c.cash, value: amount, validAfter: 0n, validBefore, nonce },
  })
  return bank.act('ATM', 'atm', `withdraw ${amount} for ${customer} by card`, [
    bank.call('CashOperations', c.cash, 'withdrawAtAtm', [branch, { customer: account, amount, validAfter: 0n, validBefore, nonce, signature }]),
  ])
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
  return bank.act(teller, 'branch', `take ${amount} in cash for ${customer}`, [
    bank.call('CashOperations', bank.contracts.cash, 'deposit', [branch, bank.account(customer), amount]),
  ])
}

// The vault custodian records a move or a count, and a supervisor confirms it.
async function underDualControl(bank: Bank, action: string, call: ReturnType<Bank['call']>): Promise<Outcome> {
  const proposed = await bank.act('vault custodian', 'branch', `record: ${action}`, [call])
  if (!proposed.ok) return proposed
  const id = eventArg<bigint>(proposed, 'OrderProposed', 'id')
  return bank.act('supervisor', 'branch', `confirm: ${action}`, [bank.call('CashOperations', bank.contracts.cash, 'approve', [id])])
}

export function moveCash(bank: Bank, from: Location, to: Location, amount: bigint, action: string): Promise<Outcome> {
  return underDualControl(bank, action, bank.call('CashOperations', bank.contracts.cash, 'proposeMove', [from, to, amount]))
}

export function countCash(bank: Bank, at: Location, counted: bigint, what: string): Promise<Outcome> {
  return underDualControl(bank, `count ${what}`, bank.call('CashOperations', bank.contracts.cash, 'proposeCount', [at, counted]))
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

// Anyone may release payments waiting in the queue: the release chooses nothing.
export function releasePayments(bank: Bank, max = 50n): Promise<Outcome> {
  return bank.act('back office', 'head office', 'release queued payments', [bank.call('Payments', bank.contracts.payments, 'release', [max])])
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
