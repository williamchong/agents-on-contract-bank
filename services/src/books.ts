// The bank's books as the contracts number them, and the opening balance sheet in docs/scenarios.md that
// every run starts from.

import { zeroAddress, type Address } from 'viem'

// One Hong Kong dollar, in the token's cents.
export const HKD = 100n

// GeneralLedger.Account, in its order.
export const Ledger = {
  Settlement: 0,
  Cash: 1,
  Securities: 2,
  Loans: 3,
  Allowance: 4,
  ReserveSurplus: 5,
  DueFromReserve: 6,
  Deposits: 7,
  Equity: 8,
} as const

// CashOperations.Place, in its order.
export const Place = { Vault: 0, Drawer: 1, Atm: 2 } as const

export interface Location {
  place: number
  branch: bigint
  holder: Address
}

export function vault(branch = 1n): Location {
  return { place: Place.Vault, branch, holder: zeroAddress }
}

export function drawer(teller: Address, branch = 1n): Location {
  return { place: Place.Drawer, branch, holder: teller }
}

export function atm(machine: Address, branch = 1n): Location {
  return { place: Place.Atm, branch, holder: machine }
}

// Payments.Status, in its order.
export const PaymentStatus = { None: 0, Credited: 1, Screening: 2, Suspense: 3, Cleared: 4, Queued: 5, Sent: 6, Returned: 7, Rejected: 8 } as const

export const Customers = ['Alice', 'Bob', 'Carol', 'Dave'] as const
export type CustomerName = (typeof Customers)[number]
// Every holder on the opening balance sheet: the four customers the story follows, and the rest together.
export const Holders = [...Customers, 'other customers'] as const

export const Opening = {
  deposits: {
    Alice: 100_000n * HKD,
    Bob: 100_000n * HKD,
    Carol: 50_000n * HKD,
    Dave: 50_000n * HKD,
    'other customers': 12_000_000n * HKD,
  } as Record<(typeof Holders)[number], bigint>,
  settlement: 1_000_000n * HKD,
  cash: 500_000n * HKD,
  securities: 2_500_000n * HKD,
  loans: 9_300_000n * HKD,
  allowance: 93_000n * HKD,
  equity: 907_000n * HKD,
  // How the cash splits between the vault, the teller's drawer and the ATM, as docs/roles.md gives it.
  vault: 250_000n * HKD,
  drawer: 50_000n * HKD,
  atm: 200_000n * HKD,
} as const
