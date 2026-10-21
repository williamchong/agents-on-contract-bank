// The bank as the chain reports it, read directly from the contracts at each new block: the bank map's and
// the balance sheet's figures, as services/src/state.ts reads them. The addresses come from the control
// service's deployment. See docs/plan.md open questions 15 and 23.

import { createPublicClient, http } from 'viem'
import { onScopeDispose, ref, shallowRef, watch, type Ref } from 'vue'
import { Accounts, readBank, type Account, type BankState } from '@bank/services/state'
import type { Deployment } from '~/lib/story'

export { hkd, HKD, MIN_CAPITAL, MIN_LIQUIDITY, OPENING_SETTLEMENT } from '~/lib/money'
export { Accounts, type BankState }

export function useBank(deployment: Ref<Deployment | undefined>, rpcUrl = 'http://localhost:8545') {
  const state = shallowRef<BankState>()
  const error = ref<string>()
  // The reads of one block go to the node together.
  const client = createPublicClient({ transport: http(rpcUrl, { batch: true }) })
  let stop: (() => void) | undefined
  let disposed = false

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
        const next = await readBank(client, d, block)
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
