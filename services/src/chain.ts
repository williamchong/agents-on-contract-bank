// The connection to the chain: a client to read it, and the relayer the submission service pays gas from.
// On the local chain the scenario clock also moves block time, which every time lock, limit and signature
// window reads. See docs/plan.md open question 11.

import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  custom,
  http,
  type Address,
  type PublicClient,
  type TestClient,
  type Transport,
  type WalletClient,
} from 'viem'

export interface Chain {
  client: PublicClient
  wallet: WalletClient
  // Moves time on the local chain only.
  test: TestClient
  // The account the submission service pays gas from. It holds no role.
  relayer: Address
  chainId: number
}

// An EIP-1193 provider, such as Hardhat's, or a node's URL.
export type Provider = Parameters<typeof custom>[0] | string

export async function connect(provider: Provider): Promise<Chain> {
  const transport: Transport = typeof provider === 'string' ? http(provider) : custom(provider)
  const client = createPublicClient({ transport })
  const wallet = createWalletClient({ transport })
  const test = createTestClient({ mode: 'hardhat', transport })
  const [relayer] = await wallet.getAddresses()
  if (!relayer) throw new Error('The chain offers no funded account to relay from')
  return { client, wallet, test, relayer, chainId: await client.getChainId() }
}

export async function blockTime(chain: Chain): Promise<bigint> {
  return (await chain.client.getBlock()).timestamp
}

// Moves block time forward on the local chain and mines a block at the new time.
export async function advance(chain: Chain, seconds: bigint): Promise<void> {
  await chain.test.increaseTime({ seconds: Number(seconds) })
  await chain.test.mine({ blocks: 1 })
}

export function snapshot(chain: Chain): Promise<string> {
  return chain.test.snapshot()
}

export function revertTo(chain: Chain, id: string): Promise<void> {
  return chain.test.revert({ id: id as `0x${string}` })
}
