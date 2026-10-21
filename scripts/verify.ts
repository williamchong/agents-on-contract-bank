// Verifies the source of every contract of the bank recorded on Base Sepolia, on Etherscan, which Basescan
// shows, and on Sourcify: `pnpm verify:base-sepolia`, with ETHERSCAN_API_KEY in the environment or .env.
// The recording keeps only addresses, so each contract's constructor arguments are read back from the
// transaction that created it. Exits non-zero if any contract is left unverified. See docs/plan.md open
// question 18.
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import hre from 'hardhat'
import { verifyContract } from '@nomicfoundation/hardhat-verify/verify'
import { constructorArgsOf, contractArtifacts, qualifiedName, type ContractName, type Contracts } from '@bank/services'

const env = fileURLToPath(new URL('../.env', import.meta.url))
if (existsSync(env)) process.loadEnvFile(env)

const { deployment } = JSON.parse(readFileSync(new URL('../recordings/base-sepolia.json', import.meta.url), 'utf8')) as {
  deployment: { contracts: Contracts; customers: Record<string, string>; staff: Record<string, string> }
}

// The contract each of the deployment's addresses is; every party acts from a multi-signer account.
const targets = new Map<string, ContractName>()
for (const [key, address] of Object.entries(deployment.contracts) as [keyof Contracts, string][]) {
  targets.set(address.toLowerCase(), contractArtifacts[key])
}
for (const address of [...Object.values(deployment.customers), ...Object.values(deployment.staff)]) {
  targets.set(address.toLowerCase(), 'MultiSignerAccount')
}

const { provider, verification } = await hre.network.getOrCreate()

// Etherscan names the transaction that created each contract, for at most five addresses a request, and
// turns away more than a few requests a second.
const CREATION_BATCH = 5
const created = new Map<string, `0x${string}`>()
const addresses = [...targets.keys()]
for (let i = 0; i < addresses.length; i += CREATION_BATCH) {
  if (i) await new Promise((resolve) => setTimeout(resolve, 500))
  const response = await verification.etherscan.customApiCall({
    module: 'contract',
    action: 'getcontractcreation',
    contractaddresses: addresses.slice(i, i + CREATION_BATCH).join(','),
  })
  if (response.status !== '1') throw new Error(`Etherscan could not name the creation transactions: ${response.message}`)
  for (const r of response.result as { contractAddress: string; txHash: `0x${string}` }[]) {
    created.set(r.contractAddress.toLowerCase(), r.txHash)
  }
}

const unverified = new Set<string>()
for (const [address, name] of targets) {
  const hash = created.get(address)
  if (!hash) throw new Error(`Etherscan named no creation transaction for ${name} at ${address}`)
  const tx = (await provider.request({ method: 'eth_getTransactionByHash', params: [hash] })) as { input: `0x${string}` } | null
  if (!tx) throw new Error(`The node has no transaction ${hash}, which created ${name} at ${address}`)
  const constructorArgs = constructorArgsOf(name, tx.input)
  for (const explorer of ['etherscan', 'sourcify'] as const) {
    const args = { address, constructorArgs: [...constructorArgs], contract: qualifiedName(name), provider: explorer, creationTxHash: hash }
    // True once verified, or if it was already; false or an error otherwise.
    const verified = await verifyContract(args, hre).catch((e: unknown) => {
      console.log(`${name} at ${address} on ${explorer}: ${e instanceof Error ? e.message : String(e)}`)
      return false
    })
    if (!verified) {
      unverified.add(address)
      console.log(`FAILED  ${name} at ${address} on ${explorer}`)
    }
  }
}
console.log(`Verified ${targets.size - unverified.size} of ${targets.size} contracts on both explorers`)
if (unverified.size) process.exitCode = 1
