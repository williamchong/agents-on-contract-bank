// The bank as the chain reports it, read directly from the contracts at each new block. This is the bank
// map's first source; it moves to the indexer's feed once the indexer exists. See docs/plan.md open
// question 15. The addresses come from the deployment, written to public/bank.json by `pnpm local`.

import { createPublicClient, http, parseAbi, type Address, type Hex } from 'viem'
import { onScopeDispose, ref, shallowRef } from 'vue'

// One Hong Kong dollar, in the token's cents.
export const HKD = 100n
// The settlement account on the opening balance sheet in docs/scenarios.md.
export const OPENING_SETTLEMENT = 1_000_000n * HKD

interface Deployment {
  chainId: number
  contracts: { token: Address; ledger: Address; cash: Address; payments: Address; assisted: Address }
  customers: Record<string, Address>
  cash: { vault: Hex; drawer: Hex; atm: Hex }
}

export interface BankState {
  block: bigint
  customers: { name: string; balance: bigint }[]
  settlement: bigint
  cash: { vault: bigint; drawer: bigint; atm: bigint }
  inPayments: bigint
  // Customers' money held at the branch for operations waiting for their approvers.
  awaitingApproval: bigint
  booksBalance: boolean
}

// GeneralLedger.Account.Settlement, as services/src/books.ts numbers it.
const SETTLEMENT = 0

const abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function balances() view returns (int256[])',
  'function cashAt(bytes32) view returns (uint256)',
  'function waitingTotal() view returns (uint256)',
])

export function useBank(rpcUrl = 'http://localhost:8545') {
  const state = shallowRef<BankState>()
  const error = ref<string>()
  // The reads of one block go to the node together.
  const client = createPublicClient({ transport: http(rpcUrl, { batch: true }) })
  let stop: (() => void) | undefined
  let disposed = false
  // Only the latest read may set the state, as an earlier one can finish after it.
  let latest = 0

  async function read(d: Deployment, blockNumber: bigint): Promise<BankState> {
    const balanceOf = (address: Address) => client.readContract({ address: d.contracts.token, abi, functionName: 'balanceOf', args: [address], blockNumber })
    const cashAt = (id: Hex) => client.readContract({ address: d.contracts.cash, abi, functionName: 'cashAt', args: [id], blockNumber })
    const names = Object.keys(d.customers).filter((n) => n !== 'other customers')
    const waiting = (address: Address) => client.readContract({ address, abi, functionName: 'waitingTotal', blockNumber })
    const [balances, ledger, vault, drawer, atm, inPayments, assistedWaiting, cashWaiting] = await Promise.all([
      Promise.all(names.map((n) => balanceOf(d.customers[n]!))),
      client.readContract({ address: d.contracts.ledger, abi, functionName: 'balances', blockNumber }),
      cashAt(d.cash.vault),
      cashAt(d.cash.drawer),
      cashAt(d.cash.atm),
      balanceOf(d.contracts.payments),
      waiting(d.contracts.assisted),
      waiting(d.contracts.cash),
    ])
    return {
      block: blockNumber,
      customers: names.map((name, i) => ({ name, balance: balances[i]! })),
      settlement: ledger[SETTLEMENT]!,
      cash: { vault, drawer, atm },
      inPayments,
      awaitingApproval: assistedWaiting + cashWaiting,
      booksBalance: ledger.reduce((a, b) => a + b, 0n) === 0n,
    }
  }

  async function refresh(d: Deployment, block: bigint) {
    const mine = ++latest
    try {
      const next = await read(d, block)
      if (mine !== latest) return
      state.value = next
      error.value = undefined
    } catch (e) {
      if (mine === latest) error.value = `Could not read the chain: ${(e as Error).message}`
    }
  }

  async function start() {
    let deployment: Deployment
    try {
      deployment = (await (await fetch('/bank.json')).json()) as Deployment
    } catch {
      error.value = 'No bank to draw yet: start the chain with `pnpm hardhat node` and deploy with `pnpm local`.'
      return
    }
    await refresh(deployment, await client.getBlockNumber())
    if (disposed) return
    stop = client.watchBlockNumber({
      pollingInterval: 1000,
      onBlockNumber: (block) => void refresh(deployment, block),
      onError: (e) => (error.value = `Could not reach the chain: ${e.message}`),
    })
  }

  void start()
  onScopeDispose(() => {
    disposed = true
    stop?.()
  })
  return { state, error }
}

// Cents to Hong Kong dollars, as the map labels them.
export function hkd(cents: bigint): string {
  return `HK$${(cents / HKD).toLocaleString('en-HK')}`
}
