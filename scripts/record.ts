// Records a run of the bank for the dashboard to play back with no chain or services running: `pnpm record`.
// On Hardhat's in-process chain, where time moves at once, it opens the bank, plays the guided tour's beats,
// then a business day of daily operation for each adverse scenario, injected after that day's routines. It
// writes the deployment, the story, the scenario cards and the bank's state at every block of the run to
// dashboard/public/recording.json. Each state is read during the run, at its own block, so nothing reads old
// state afterwards. Exits non-zero if any card fails. See docs/plan.md open question 18.
import { mkdirSync, writeFileSync } from 'node:fs'
import { network } from 'hardhat'
import { connect, Control, presets, readBank, toJson, type BankState, type Card } from '@bank/services'

const out = new URL('../dashboard/public/recording.json', import.meta.url)

const { provider } = await network.getOrCreate()
const chain = await connect(provider)
const control = new Control(chain)
await control.open()
control.setPace(0)
const deployment = await control.deployment()

const states = new Map<bigint, Promise<BankState>>()
function snapshot(number: bigint) {
  if (states.has(number)) return
  const read = chain.client.getBlock({ blockNumber: number }).then((block) => readBank(chain.client, deployment, block, true))
  // A failed read is reported when the run's states are gathered, not as an unhandled rejection mid-run.
  read.catch(() => {})
  states.set(number, read)
}
const opening = await chain.client.getBlockNumber()
snapshot(opening)
control.onLine((line) => snapshot(line.block))

// The cards the scenario card shows: the tour's beats and the adverse scenarios, and a routine only if it
// fails, as in daily operation.
const cards: Card[] = []
const show = (card: Card) => {
  if (card.kind !== 'routine' || card.status !== 'passed') cards.push(card)
}
for (let i = 0; i < deployment.beats.length; i++) show(await control.nextTourBeat())
for (const scenario of presets.filter((p) => p.kind === 'adverse')) {
  for (const routine of presets.filter((p) => p.kind === 'routine')) show(await control.runPreset(routine.name, true))
  show(await control.runPreset(scenario.name))
  await control.nextDay()
}

const { lines } = control.state()
const recorded = await Promise.all(states.values())
mkdirSync(new URL('.', out), { recursive: true })
writeFileSync(out, toJson({ deployment, opening, lines, cards, states: recorded }))
const failed = cards.filter((c) => c.status !== 'passed')
console.log(`Recorded ${lines.length} lines, ${cards.length} cards and ${recorded.length} blocks to ${out.pathname}`)
for (const card of failed) console.log(`FAILED  ${card.title}${card.error ? `: ${card.error}` : ''}`)
if (failed.length) process.exitCode = 1
