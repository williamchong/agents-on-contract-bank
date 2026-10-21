// Records a run of the bank for the dashboard to play back with no chain or services running: `pnpm record`.
// On Hardhat's in-process chain, where time moves at once, it opens the bank, plays the guided tour's beats,
// then a business day of daily operation for each adverse scenario, injected after that day's routines. It
// writes the deployment, the story, the scenario cards and the bank's state at every block of the run to
// dashboard/public/recording.json. Each state is read during the run, at its own block, so nothing reads old
// state afterwards. Exits non-zero if any card fails. See docs/plan.md open question 18.
//
// `pnpm record:base-sepolia` records the run on Base Sepolia instead, relayed from the account whose key is
// BASE_SEPOLIA_PRIVATE_KEY, in the environment or .env, and writes it to recordings/base-sepolia.json, which
// the published playback plays. Its clock cannot be moved, so the time locks are waited out in real time and
// the daily routines run once, the adverse scenarios following on the same day, which a day's limits leave
// room for.
import { existsSync, mkdirSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { network } from 'hardhat'
import { connect, Control, presets, readBank, toJson, type BankState, type Card } from '@bank/services'

const { provider, networkName } = await network.getOrCreate()
const onBaseSepolia = networkName === 'baseSepolia'
const out = new URL(onBaseSepolia ? '../recordings/base-sepolia.json' : '../dashboard/public/recording.json', import.meta.url)

async function connectBaseSepolia() {
  const env = fileURLToPath(new URL('../.env', import.meta.url))
  if (existsSync(env)) process.loadEnvFile(env)
  const key = process.env.BASE_SEPOLIA_PRIVATE_KEY
  if (!key) throw new Error('Set BASE_SEPOLIA_PRIVATE_KEY, in the environment or .env, to the funded relayer key')
  return connect(process.env.BASE_SEPOLIA_RPC_URL!, key as `0x${string}`)
}

const chain = onBaseSepolia ? await connectBaseSepolia() : await connect(provider)
const control = new Control(chain)
if (onBaseSepolia) console.log(`Opening the bank on Base Sepolia from ${chain.relayer}; each time lock takes ten minutes`)
await control.open()
control.setPace(0)
const deployment = await control.deployment()

const states = new Map<bigint, Promise<BankState>>()
function snapshot(number: bigint, timestamp: bigint) {
  if (states.has(number)) return
  const read = readBank(chain.client, deployment, { number, timestamp }, true)
  // A failed read is reported when the run's states are gathered, not as an unhandled rejection mid-run.
  read.catch(() => {})
  states.set(number, read)
}
const { number: opening, timestamp } = await chain.client.getBlock()
snapshot(opening, timestamp)
control.onLine((line) => {
  snapshot(line.block, line.time)
  if (onBaseSepolia) console.log(`${line.seq} ${line.kind} ${line.actor}: ${line.action}${line.tx ? ` ${line.tx}` : ''}`)
})

// The cards the scenario card shows: the tour's beats and the adverse scenarios, and a routine only if it
// fails, as in daily operation.
const cards: Card[] = []
const show = (card: Card) => {
  if (card.kind !== 'routine' || card.status !== 'passed') cards.push(card)
}
const routines = presets.filter((p) => p.kind === 'routine')
const scenarios = presets.filter((p) => p.kind === 'adverse')
const runRoutines = async () => {
  for (const routine of routines) show(await control.runPreset(routine.name, true))
}
for (let i = 0; i < deployment.beats.length; i++) show(await control.nextTourBeat())
if (chain.local) {
  for (const scenario of scenarios) {
    await runRoutines()
    show(await control.runPreset(scenario.name))
    await control.nextDay()
  }
} else {
  await runRoutines()
  for (const scenario of scenarios) show(await control.runPreset(scenario.name))
}

const { lines } = control.state()
const recorded = await Promise.all(states.values())
mkdirSync(new URL('.', out), { recursive: true })
writeFileSync(out, toJson({ deployment, opening, lines, cards, states: recorded }))
const failed = cards.filter((c) => c.status !== 'passed')
console.log(`Recorded ${lines.length} lines, ${cards.length} cards and ${recorded.length} blocks to ${out.pathname}`)
for (const card of failed) console.log(`FAILED  ${card.title}${card.error ? `: ${card.error}` : ''}`)
if (failed.length) process.exitCode = 1
