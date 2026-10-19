// Plays every preset on Hardhat's in-process chain and scores it, with no API key and nothing else
// running: `pnpm scenarios`. Each runs from the same starting state, then all of them run again in order
// on one bank, as the control panel runs them. Exits non-zero if any fails. To run some only, name them
// in PRESETS, comma separated, such as PRESETS=atm,ledger; that skips the run in order.
import { network } from 'hardhat'
import { connect, report, reportCards, runInOrder, runPresets } from '@bank/services'

const names = (process.env.PRESETS ?? '').split(',').map((n) => n.trim().toLowerCase()).filter(Boolean)
const { provider } = await network.getOrCreate()
const chain = await connect(provider)
const { results } = await runPresets(chain, names.length ? (p) => names.some((n) => p.name.toLowerCase().includes(n)) : undefined)
console.log(report(results))
if (results.some((r) => !r.passed)) process.exitCode = 1
if (!names.length) {
  const cards = await runInOrder(chain)
  console.log(`\n${reportCards(cards)}`)
  if (cards.some((c) => c.status !== 'passed')) process.exitCode = 1
}
