// The connection to the chain: a client to read it, and the relayer the submission service pays gas from.
// On the local chain the scenario clock also moves block time, which every time lock, limit and signature
// window reads; on a public chain, whose clock cannot be moved, it waits for block time to pass instead.
// See docs/plan.md open question 11.

import {
  createPublicClient,
  createTestClient,
  concat,
  createWalletClient,
  custom,
  http,
  keccak256,
  toHex,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type TestClient,
  type Transport,
  type WalletClient,
} from 'viem'
import { nonceManager, privateKeyToAccount } from 'viem/accounts'
import { baseSepolia, hardhat } from 'viem/chains'

export interface Chain {
  client: PublicClient
  wallet: WalletClient<Transport, undefined, Account>
  // Moves time on the local chain only.
  test: TestClient
  // The account the submission service pays gas from. It holds no role.
  relayer: Address
  chainId: number
  // Whether block time can be moved, as on Hardhat's chains.
  local: boolean
  // On a public chain, the secret every signing key is derived with, so the keys cannot be worked out from
  // their names in this repository.
  keySeed?: Hex
}

// An EIP-1193 provider, such as Hardhat's, or a node's URL.
export type Provider = Parameters<typeof custom>[0] | string

// Public chains the bank is deployed to, whose Multicall3 lets the recorder read a block's state in one
// request.
const publicChains = [baseSepolia]

// Connects to the chain. On a public chain the node holds no keys, so the relayer's own key is passed in and
// signs here.
export async function connect(provider: Provider, key?: Hex): Promise<Chain> {
  // A public endpoint limits its rate, so requests it turns away are retried, waiting longer each time.
  const transport: Transport =
    typeof provider === 'string' ? http(provider, { retryCount: 10, retryDelay: 500 }) : custom(provider)
  const chainId = await createPublicClient({ transport }).getChainId()
  // Hardhat's chains, local or in-process, whose block time the scenario clock moves.
  const local = chainId === hardhat.id
  const known = publicChains.find((c) => c.id === chainId)
  const client = createPublicClient({
    transport,
    chain: known,
    batch: known ? { multicall: true } : undefined,
    pollingInterval: local ? undefined : 1_000,
  }) as PublicClient
  // The nonce is counted here, as a node behind a public endpoint may not yet have seen the last transaction.
  const account = key ? privateKeyToAccount(key, { nonceManager }) : undefined
  const relayer = account?.address ?? (await createWalletClient({ transport }).getAddresses())[0]
  if (!relayer) throw new Error('The chain offers no funded account to relay from')
  const wallet = createWalletClient({ transport, account: account ?? relayer })
  const test = createTestClient({ mode: 'hardhat', transport })
  // Derived from the relayer's key rather than kept as a second secret; a new run deploys a new bank, so
  // nothing needs the seed afterwards.
  const keySeed = key && keccak256(concat([key, toHex('signing keys')]))
  return { client, wallet, test, relayer, chainId, local, keySeed }
}

export async function blockTime(chain: Chain): Promise<bigint> {
  return (await chain.client.getBlock()).timestamp
}

// Moves block time forward on the local chain and mines a block at the new time. On a public chain it
// waits until a block is that far on.
export async function advance(chain: Chain, seconds: bigint): Promise<void> {
  if (!chain.local) {
    let now = await blockTime(chain)
    for (const until = now + seconds; now < until; now = await blockTime(chain)) {
      await new Promise((resolve) => setTimeout(resolve, Number(until - now) * 1000))
    }
    return
  }
  await chain.test.increaseTime({ seconds: Number(seconds) })
  await chain.test.mine({ blocks: 1 })
}

export function snapshot(chain: Chain): Promise<string> {
  return chain.test.snapshot()
}

export function revertTo(chain: Chain, id: string): Promise<void> {
  return chain.test.revert({ id: id as `0x${string}` })
}
