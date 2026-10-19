// Runs presets on a freshly deployed bank, each from the same starting state, and scores them. This is
// the milestone's check: a milestone is done when its routines run and its adverse scenarios pass. See
// docs/scenarios.md.

import { deployBank, type Bank } from './bank.ts'
import { revertTo, snapshot, type Chain } from './chain.ts'
import { Clearing } from './clearing.ts'
import { presets, type Check, type Preset } from './scenarios.ts'
import type { Line } from './timeline.ts'

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
  const results: Result[] = []
  for (const preset of presets.filter(only ?? (() => true))) {
    await revertTo(chain, start)
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
