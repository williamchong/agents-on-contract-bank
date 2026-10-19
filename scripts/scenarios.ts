// Plays every preset on Hardhat's in-process chain and scores it, with no API key and nothing else
// running: `pnpm scenarios`. Exits non-zero if any preset fails. To run some only, name them in
// PRESETS, comma separated, such as PRESETS=atm,ledger.
import { network } from 'hardhat'
import { connect, report, runPresets } from '@bank/services'

const names = (process.env.PRESETS ?? '').split(',').map((n) => n.trim().toLowerCase()).filter(Boolean)
const { provider } = await network.getOrCreate()
const chain = await connect(provider)
const { results } = await runPresets(chain, names.length ? (p) => names.some((n) => p.name.toLowerCase().includes(n)) : undefined)
console.log(report(results))
if (results.some((r) => !r.passed)) process.exitCode = 1
