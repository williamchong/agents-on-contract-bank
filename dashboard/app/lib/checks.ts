// The design's headline claims as of the latest block, for the invariant strip, and what each means when it
// is opened: the claim in full, why it matters, the figures behind it and where on the map and on chain to
// check it. See docs/architecture.md#dashboard.

import { ratios, type BankState } from '~/composables/useBank'
import type { EntityId } from '~/town/entities'
import { hkd, MIN_CAPITAL, MIN_LIQUIDITY } from './money'

export type CheckKey = 'books' | 'cash' | 'clearing' | 'capital' | 'liquidity'

export interface Check {
  key: CheckKey
  label: string
  full: string
  // Whether it holds; undefined when it cannot be told yet.
  ok: boolean | undefined
  why: string
  figures: { label: string; value: string }[]
  // Where on the map it is kept, and the deployment's contracts it is read from.
  building: EntityId
  contracts: string[]
}

export function checks(s: BankState | undefined): Check[] {
  if (!s) return []
  const l = s.ledger
  const split = s.cash.vault + s.cash.drawer + s.cash.atm + s.cash.replacementDrawer
  const r = ratios(l)
  return [
    {
      key: 'books',
      label: s.booksBalance ? 'Books balance' : 'Books do not balance',
      full: 'Assets equal deposits and equity in the general ledger',
      ok: s.booksBalance,
      why: 'Every movement of money posts a balanced entry in the same transaction, and the ledger refuses one that does not balance, so the books cannot disagree with the money.',
      figures: [
        { label: 'Assets', value: hkd(r.totalAssets) },
        { label: 'Deposits and equity', value: hkd(r.totalLiabilities) },
      ],
      building: 'head-office',
      contracts: ['ledger', 'token'],
    },
    {
      key: 'cash',
      label: 'Cash adds up',
      full: 'Cash in the vault, drawers and ATM is the ledger’s cash',
      ok: split === l.Cash,
      why: 'The cash module tracks where every note is, and each cash movement posts its entry in the ledger in the same transaction, so the places add up to the ledger’s cash.',
      figures: [
        { label: 'Vault', value: hkd(s.cash.vault) },
        { label: 'Drawers', value: hkd(s.cash.drawer + s.cash.replacementDrawer) },
        { label: 'ATM', value: hkd(s.cash.atm) },
        { label: 'Ledger’s cash', value: hkd(l.Cash) },
      ],
      building: 'vault',
      contracts: ['cash', 'ledger'],
    },
    {
      key: 'clearing',
      label: s.statement ? `Clearing ${s.statement.matched ? 'matches' : 'differs'}` : 'No clearing statement',
      full: s.statement
        ? `The clearing system’s statement of the settlement account ${s.statement.matched ? 'matches' : 'does not match'} the ledger`
        : 'No statement from the clearing system yet',
      ok: s.statement ? s.statement.matched : undefined,
      why: 'The settlement account is held at the clearing system, off chain. Its signed statement is attested on chain and compared with the ledger’s balance at the statement’s date; a mismatch posts nothing and marks the figure.',
      figures: [
        { label: 'Ledger’s settlement account', value: hkd(l.Settlement) },
        ...(s.statement ? [{ label: 'Statement', value: s.statement.current ? 'Current' : 'Not current' }] : []),
      ],
      building: 'water-tower',
      contracts: ['attestations', 'ledger'],
    },
    {
      key: 'capital',
      label: `Capital ${r.capital.toFixed(1)}%`,
      full: `Capital ratio ${r.capital.toFixed(2)}%, minimum ${MIN_CAPITAL}%`,
      ok: r.capital >= MIN_CAPITAL,
      why: 'Equity over loans net of the allowance: how much loss the bank can take on its loans before depositors’ money is at risk.',
      figures: [
        { label: 'Equity', value: hkd(-l.Equity) },
        { label: 'Loans net of allowance', value: hkd(l.Loans + l.Allowance) },
        { label: 'Minimum', value: `${MIN_CAPITAL}%` },
      ],
      building: 'head-office',
      contracts: ['ledger'],
    },
    {
      key: 'liquidity',
      label: `Liquidity ${r.liquidity.toFixed(1)}%`,
      full: `Liquidity ratio ${r.liquidity.toFixed(2)}%, minimum ${MIN_LIQUIDITY}%`,
      ok: r.liquidity >= MIN_LIQUIDITY,
      why: 'Liquid assets over deposits: how much of what customers could ask for back the bank could pay out at once.',
      figures: [
        { label: 'Settlement, cash and securities', value: hkd(l.Settlement + l.Cash + l.Securities) },
        { label: 'Deposits', value: hkd(-l.Deposits) },
        { label: 'Minimum', value: `${MIN_LIQUIDITY}%` },
      ],
      building: 'head-office',
      contracts: ['ledger'],
    },
  ]
}
