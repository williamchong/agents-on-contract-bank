// The bank as the chain reports it, read directly from the contracts at each new block: the bank map's and
// the balance sheet's figures. The addresses come from the control service's deployment. See docs/plan.md
// open questions 15 and 23.

import { createPublicClient, http, parseAbi, type Address, type Hex } from 'viem'
import { onScopeDispose, ref, shallowRef, watch, type Ref } from 'vue'
import type { Deployment } from '~/lib/story'

export { hkd, HKD, MIN_CAPITAL, MIN_LIQUIDITY, OPENING_SETTLEMENT } from '~/lib/money'

// GeneralLedger.Account, in its order; keep in step with Ledger in services/src/books.ts.
export const Accounts = ['Settlement', 'Cash', 'Securities', 'Loans', 'Allowance', 'ReserveSurplus', 'DueFromReserve', 'Deposits', 'Equity'] as const
type Account = (typeof Accounts)[number]

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

const abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function balances() view returns (int256[])',
  'function cashAt(bytes32) view returns (uint256)',
  'function waitingTotal() view returns (uint256)',
  'function figure(uint8) view returns ((uint256 amount, uint256 ledgerBalance, uint256 asOf, uint256 sequence, bool matched))',
  'function isCurrent(uint8) view returns (bool)',
])

export function useBank(deployment: Ref<Deployment | undefined>, rpcUrl = 'http://localhost:8545') {
  const state = shallowRef<BankState>()
  const error = ref<string>()
  // The reads of one block go to the node together.
  const client = createPublicClient({ transport: http(rpcUrl, { batch: true }) })
  let stop: (() => void) | undefined
  let disposed = false

  // Reads the latest state rather than a block by number, which a chain reverted under the node could
  // answer from before the revert.
  async function read(d: Deployment, blockNumber: bigint, time: bigint): Promise<BankState> {
    const c = d.contracts as Record<string, Address>
    const balanceOf = (address: Address) => client.readContract({ address: c.token!, abi, functionName: 'balanceOf', args: [address] })
    const cashAt = (id: string) => client.readContract({ address: c.cash!, abi, functionName: 'cashAt', args: [id as Hex] })
    const waiting = (address: Address) => client.readContract({ address, abi, functionName: 'waitingTotal' })
    const names = Object.keys(d.customers).filter((n) => n !== 'other customers')
    const [balances, ledger, vault, drawer, atm, replacementDrawer, inPayments, assisted, atCash, figure, current] = await Promise.all([
      Promise.all(names.map((n) => balanceOf(d.customers[n] as Address))),
      client.readContract({ address: c.ledger!, abi, functionName: 'balances' }),
      cashAt(d.cash.vault!),
      cashAt(d.cash.drawer!),
      cashAt(d.cash.atm!),
      cashAt(d.cash.replacementDrawer!),
      balanceOf(c.payments!),
      waiting(c.assisted!),
      waiting(c.cash!),
      client.readContract({ address: c.attestations!, abi, functionName: 'figure', args: [0] }),
      client.readContract({ address: c.attestations!, abi, functionName: 'isCurrent', args: [0] }),
    ])
    return {
      block: blockNumber,
      time,
      customers: names.map((name, i) => ({ name, balance: balances[i]! })),
      ledger: Object.fromEntries(Accounts.map((a, i) => [a, ledger[i]!])) as Record<Account, bigint>,
      cash: { vault, drawer, atm, replacementDrawer },
      inPayments,
      awaitingApproval: assisted + atCash,
      statement: figure.sequence === 0n ? undefined : { asOf: figure.asOf, matched: figure.matched, current },
      booksBalance: ledger.reduce((a, b) => a + b, 0n) === 0n,
    }
  }

  // Each deployment's poller has its own generation, so one left from an earlier deployment stops
  // instead of writing the old bank's figures.
  let generation = 0

  // Watches the latest block by its hash, which changes whenever the chain does. One read at a time, so a
  // slow read is never overtaken by the next and discarded; the next tick picks up whatever block is
  // latest by then.
  async function start(d: Deployment) {
    stop?.()
    const mine = ++generation
    let last: string | undefined
    let reading = false
    const tick = async () => {
      if (reading || mine !== generation) return
      reading = true
      try {
        const block = await client.getBlock()
        if (block.hash === last) return
        last = block.hash ?? undefined
        const next = await read(d, block.number, block.timestamp)
        if (mine !== generation) return
        state.value = next
        error.value = undefined
        // A block mined while the reads were out may have left them straddling two blocks; read again.
        if ((await client.getBlock()).hash !== last) last = undefined
      } catch (e) {
        error.value = `Could not reach the chain: ${(e as Error).message}`
      } finally {
        reading = false
      }
    }
    const timer = setInterval(() => void tick(), 500)
    stop = () => clearInterval(timer)
    if (disposed) stop()
    await tick()
  }

  watch(deployment, (d) => d && void start(d), { immediate: true })
  onScopeDispose(() => {
    disposed = true
    stop?.()
  })
  return { state, error }
}

// Equity over loans net of the allowance, and liquid assets over deposits, as docs/architecture.md defines
// the two ratios, in per cent to two places, with the totals of each side of the balance sheet.
export function ratios(ledger: Record<Account, bigint>) {
  const equity = -ledger.Equity
  const netLoans = ledger.Loans + ledger.Allowance
  const liquid = ledger.Settlement + ledger.Cash + ledger.Securities
  const deposits = -ledger.Deposits
  const percent = (a: bigint, b: bigint) => (b === 0n ? 0 : Number((a * 10_000n) / b) / 100)
  return {
    capital: percent(equity, netLoans),
    liquidity: percent(liquid, deposits),
    totalAssets: liquid + netLoans,
    totalLiabilities: deposits + equity,
  }
}
