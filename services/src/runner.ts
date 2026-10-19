// Runs presets on a freshly deployed bank, each from the same starting state, and scores them. This is
// the milestone's check: a milestone is done when its routines run and its adverse scenarios pass. See
// docs/scenarios.md.

import { deployBank, type Bank } from './bank.ts'
import { revertTo, snapshot, type Chain } from './chain.ts'
import { Clearing } from './clearing.ts'
import { Control, type Card } from './control.ts'
import { presets, type Check, type Preset } from './scenarios.ts'
import type { Line } from './timeline.ts'
import { beats } from './tour.ts'

export interface Result {
  preset: Preset
  checks: Check[]
  passed: boolean
  lines: Line[]
  error?: string
}

export async function runPresets(chain: Chain, only?: (p: Preset) => boolean): Promise<{ bank: Bank; results: Result[] }> {
  const bank = await deployBank(chain)
  let start = await snapshot(chain)
  // The parties' devices and roles change with the chain, so they go back with it.
  const restore = bank.remember()
  const results: Result[] = []
  for (const preset of presets.filter(only ?? (() => true))) {
    await revertTo(chain, start)
    restore()
    // A snapshot is used up by reverting to it.
    start = await snapshot(chain)
    const from = bank.timeline.lines.length
    const clearing = await Clearing.open(bank)
    try {
      const checks = await preset.run({ bank, clearing })
      results.push({ preset, checks, passed: checks.every((c) => c.pass), lines: bank.timeline.lines.slice(from) })
    } catch (e) {
      const error = e instanceof Error ? e.message : String(e)
      results.push({ preset, checks: [], passed: false, lines: bank.timeline.lines.slice(from), error })
    }
  }
  return { bank, results }
}

// Plays what the control panel offers on one bank, in order, as a presenter does without resetting: the
// tour, then daily operation and every adverse scenario, twice. Each must leave a bank the next can run on.
export async function runInOrder(chain: Chain, rounds = 2): Promise<Card[]> {
  const control = new Control(chain)
  await control.open()
  control.setPace(0)
  const cards: Card[] = []
  for (const _ of beats) cards.push(await control.nextTourBeat())
  for (let round = 0; round < rounds; round++) {
    cards.push(await control.runDaily())
    for (const p of presets.filter((p) => p.kind === 'adverse')) cards.push(await control.runPreset(p.name))
  }
  return cards
}

export function reportCards(cards: Card[]): string {
  const out = cards.flatMap((c) => [
    `${c.status === 'passed' ? 'PASS' : 'FAIL'}  ${c.title}`,
    ...(c.error ? [`      error: ${c.error}`] : []),
    ...c.checks.filter((x) => !x.pass).map((x) => `      ✘ ${x.name}${x.detail ? `: ${x.detail}` : ''}`),
  ])
  out.push('', `${cards.filter((c) => c.status === 'passed').length} of ${cards.length} passed in order on one bank`)
  return out.join('\n')
}

export function report(results: Result[]): string {
  const out: string[] = []
  for (const r of results) {
    const label = r.preset.kind === 'adverse' ? 'scenario' : 'routine'
    const verdict = !r.passed ? 'FAIL' : r.preset.waitsFor?.length ? 'PASS (partial)' : 'PASS'
    out.push(`${verdict}  ${label}: ${r.preset.name}${r.preset.control ? ` (${r.preset.control})` : ''}`)
    if (r.error) out.push(`      error: ${r.error}`)
    for (const c of r.checks) out.push(`      ${c.pass ? '✔' : '✘'} ${c.name}${c.pass || !c.detail ? '' : `: ${c.detail}`}`)
    for (const w of r.preset.waitsFor ?? []) out.push(`      … waits for ${w}`)
  }
  const passed = results.filter((r) => r.passed).length
  const partial = results.filter((r) => r.passed && r.preset.waitsFor?.length).length
  out.push('', `${passed} of ${results.length} presets passed, ${partial} of them in part`)
  return out.join('\n')
}
