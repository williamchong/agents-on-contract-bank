// Deploys the bank to a running local chain and plays the daily routines on it, so the dashboard has a
// live bank to draw. Start the chain with `pnpm hardhat node`, then run `pnpm local`. The addresses the
// dashboard reads are written to dashboard/public/bank.json, and the run's timeline beside them.
import { mkdirSync, writeFileSync } from 'node:fs'
import { network } from 'hardhat'
import { Clearing, connect, deployBank, Holders, locationId, places, presets, Timeline, toJson } from '@bank/services'

const out = new URL('../dashboard/public/', import.meta.url)
mkdirSync(out, { recursive: true })

const { provider } = await network.getOrCreate('localhost')
const chain = await connect(provider)
const bank = await deployBank(chain, new Timeline(new URL('timeline.jsonl', out).pathname))

writeFileSync(
  new URL('bank.json', out),
  toJson({
    chainId: chain.chainId,
    contracts: bank.contracts,
    customers: Object.fromEntries(Holders.map((n) => [n, bank.account(n)])),
    cash: Object.fromEntries(await Promise.all(Object.entries(places(bank)).map(async ([k, at]) => [k, await locationId(bank, at)]))),
  }),
)
console.log(`Deployed. Addresses written to ${new URL('bank.json', out).pathname}`)

const clearing = await Clearing.open(bank)
for (const preset of presets.filter((p) => p.kind === 'routine')) {
  const checks = await preset.run({ bank, clearing })
  console.log(`${checks.every((c) => c.pass) ? 'ran' : 'FAILED'}: ${preset.name}`)
}
