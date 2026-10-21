// The bank as the chain reports it at one block: the figures the bank map, the balance sheet and the
// invariant strip draw. The live dashboard reads it at each new block, and the recorder at each block of a
// run, for the dashboard to play back. It imports nothing that needs Node, so the dashboard can use it.
// See docs/plan.md open questions 15, 18 and 23.

import { parseAbi, type Address, type Hex, type PublicClient } from 'viem'
import { Ledger } from './books.ts'

export type Account = keyof typeof Ledger
// GeneralLedger.Account, in its order.
export const Accounts = Object.keys(Ledger) as Account[]

export interface BankState {
  block: bigint
  // The block's time, against which the balance sheet ages each attested figure.
  time: bigint
  customers: { name: string; balance: bigint }[]
  ledger: Record<Account, bigint>
  cash: { vault: bigint; drawer: bigint; atm: bigint; replacementDrawer: bigint }
  inPayments: bigint
  // Customers' money held at the branch for operations waiting for their approvers.
  awaitingApproval: bigint
  // The clearing system's latest statement of the settlement account, compared with the ledger.
  statement: { asOf: bigint; matched: boolean; current: boolean } | undefined
  booksBalance: boolean
}

// Where the bank's contracts, customers and cash locations are, as the control service's deployment gives
// them.
export interface BankAddresses {
  contracts: Partial<Record<'token' | 'ledger' | 'cash' | 'payments' | 'assisted' | 'attestations', string>>
  customers: Record<string, string>
  cash: Record<string, string>
}

const abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function balances() view returns (int256[])',
  'function cashAt(bytes32) view returns (uint256)',
  'function waitingTotal() view returns (uint256)',
  'function figure(uint8) view returns ((uint256 amount, uint256 ledgerBalance, uint256 asOf, uint256 sequence, bool matched))',
  'function isCurrent(uint8) view returns (bool)',
])

// Reads the bank as of `block`. Pinned, every read names the block; otherwise it reads the latest state,
// which a chain reverted under the node cannot answer from before the revert.
export async function readBank(
  client: PublicClient,
  d: BankAddresses,
  block: { number: bigint; timestamp: bigint },
  pinned = false,
): Promise<BankState> {
  const c = d.contracts as Partial<Record<keyof BankAddresses['contracts'], Address>>
  const at = pinned ? { blockNumber: block.number } : {}
  const balanceOf = (address: Address) => client.readContract({ address: c.token!, abi, functionName: 'balanceOf', args: [address], ...at })
  const cashAt = (id: string) => client.readContract({ address: c.cash!, abi, functionName: 'cashAt', args: [id as Hex], ...at })
  const waiting = (address: Address) => client.readContract({ address, abi, functionName: 'waitingTotal', ...at })
  const names = Object.keys(d.customers).filter((n) => n !== 'other customers')
  const [balances, ledger, vault, drawer, atm, replacementDrawer, inPayments, assisted, atCash, figure, current] = await Promise.all([
    Promise.all(names.map((n) => balanceOf(d.customers[n] as Address))),
    client.readContract({ address: c.ledger!, abi, functionName: 'balances', ...at }),
    cashAt(d.cash.vault!),
    cashAt(d.cash.drawer!),
    cashAt(d.cash.atm!),
    cashAt(d.cash.replacementDrawer!),
    balanceOf(c.payments!),
    waiting(c.assisted!),
    waiting(c.cash!),
    client.readContract({ address: c.attestations!, abi, functionName: 'figure', args: [0], ...at }),
    client.readContract({ address: c.attestations!, abi, functionName: 'isCurrent', args: [0], ...at }),
  ])
  return {
    block: block.number,
    time: block.timestamp,
    customers: names.map((name, i) => ({ name, balance: balances[i]! })),
    ledger: Object.fromEntries(Accounts.map((a, i) => [a, ledger[i]!])) as Record<Account, bigint>,
    cash: { vault, drawer, atm, replacementDrawer },
    inPayments,
    awaitingApproval: assisted + atCash,
    statement: figure.sequence === 0n ? undefined : { asOf: figure.asOf, matched: figure.matched, current },
    booksBalance: ledger.reduce((a, b) => a + b, 0n) === 0n,
  }
}

// A state written out as JSON, its amounts as decimal strings, read back.
export function parseBankState(raw: unknown): BankState {
  const s = raw as Record<string, any>
  const big = (v: string | number) => BigInt(v)
  return {
    block: big(s.block),
    time: big(s.time),
    customers: s.customers.map((c: { name: string; balance: string }) => ({ name: c.name, balance: big(c.balance) })),
    ledger: Object.fromEntries(Accounts.map((a) => [a, big(s.ledger[a])])) as Record<Account, bigint>,
    cash: { vault: big(s.cash.vault), drawer: big(s.cash.drawer), atm: big(s.cash.atm), replacementDrawer: big(s.cash.replacementDrawer) },
    inPayments: big(s.inPayments),
    awaitingApproval: big(s.awaitingApproval),
    statement: s.statement && { asOf: big(s.statement.asOf), matched: s.statement.matched, current: s.statement.current },
    booksBalance: s.booksBalance,
  }
}
