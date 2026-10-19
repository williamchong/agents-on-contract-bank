// The run's timeline: every request the submission service carried, allowed or refused, and every
// operator command, in order. Refusals leave nothing on chain, so they are recorded here as they happen.
// The story view, the bank map and the public replay read it; see docs/architecture.md#story-lines.

import { appendFileSync, writeFileSync } from 'node:fs'
import type { Address, Hex } from 'viem'

export interface ChainEvent {
  contract: string
  address: Address
  name: string
  args: Record<string, unknown>
}

export interface Line {
  seq: number
  // Block time of the block the line belongs to.
  time: bigint
  block: bigint
  kind: 'allowed' | 'refused' | 'operator'
  actor: string
  channel: string
  action: string
  tx?: Hex
  // For a refusal, the rule that stopped it, as the contract's error and its arguments.
  reason?: { error: string; args: unknown[] }
  events: ChainEvent[]
}

export class Timeline {
  readonly lines: Line[] = []
  private readonly file: string | undefined
  private readonly listeners = new Set<(line: Line) => void>()

  // With a file, each line is also written to it as one line of JSON, so a reader can follow the run.
  constructor(file?: string) {
    this.file = file
    if (file) writeFileSync(file, '')
  }

  add(line: Omit<Line, 'seq'>): Line {
    const full = { seq: this.lines.length + 1, ...line }
    this.lines.push(full)
    if (this.file) appendFileSync(this.file, `${toJson(full)}\n`)
    for (const listener of this.listeners) listener(full)
    return full
  }

  // Calls `listener` with every line added from now on, until the returned function is called.
  subscribe(listener: (line: Line) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  // Starts the timeline again, as a reset of the run does.
  clear(): void {
    this.lines.length = 0
    if (this.file) writeFileSync(this.file, '')
  }
}

export function toJson(value: unknown): string {
  return JSON.stringify(value, (_, v) => (typeof v === 'bigint' ? v.toString() : v))
}
