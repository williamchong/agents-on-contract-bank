// The submission service: simulates each signed request before sending it, sends it from the relayer,
// which pays the gas, and reports the outcome to the timeline, refusals included, since a refused request
// leaves nothing on chain. A request's authority comes from the signatures inside it, never from who
// sent it. See docs/architecture.md#channels.

import {
  BaseError,
  decodeErrorResult,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from 'viem'
import { allAbis } from './artifacts.ts'
import type { Chain } from './chain.ts'
import type { ChainEvent, Line, Timeline } from './timeline.ts'

export interface Request {
  // Who acted, as the story view names them, such as "teller of branch 1" or "Alice".
  actor: string
  // The channel the request came through, such as branch, atm, app, partner or admin.
  channel: string
  // What was attempted, in plain words.
  action: string
  to: Address
  data: Hex
  // Shown when the line is opened: the keys that signed, and the role the request is checked against.
  signers?: string[]
  role?: string
}

export type Outcome =
  | { ok: true; line: Line; receipt: TransactionReceipt; events: ChainEvent[] }
  | { ok: false; line: Line; error: string; args: unknown[] }

export class Submission {
  private readonly chain: Chain
  private readonly timeline: Timeline
  private readonly abi: Abi
  // The contract each address is, so events read as "Payments.CreditReceived".
  readonly names = new Map<string, string>()
  // A pause before each request, so an audience can follow a demo; none when scoring presets.
  pace = 0
  // While the operator has paused the run, the next request waits here.
  private paused: { done: Promise<void>; resume: () => void } | undefined

  pause(): void {
    if (this.paused) return
    let resume!: () => void
    const done = new Promise<void>((r) => (resume = r))
    this.paused = { done, resume }
  }

  resume(): void {
    this.paused?.resume()
    this.paused = undefined
  }

  get isPaused(): boolean {
    return this.paused !== undefined
  }

  constructor(chain: Chain, timeline: Timeline) {
    this.chain = chain
    this.timeline = timeline
    this.abi = allAbis()
  }

  name(address: Address, contract: string): void {
    this.names.set(address.toLowerCase(), contract)
  }

  async submit(request: Request): Promise<Outcome> {
    if (this.pace) await new Promise((resolve) => setTimeout(resolve, this.pace))
    while (this.paused) await this.paused.done
    const { client, wallet } = this.chain
    const refusal = await this.simulate(request)
    if (refusal) {
      const block = await client.getBlock()
      const line = this.timeline.add({
        time: block.timestamp,
        block: block.number,
        kind: 'refused',
        actor: request.actor,
        channel: request.channel,
        action: request.action,
        signers: request.signers,
        role: request.role,
        reason: refusal,
        events: [],
      })
      return { ok: false, line, ...refusal }
    }

    const hash = await wallet.sendTransaction({ chain: null, to: request.to, data: request.data })
    const receipt = await client.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error(`${request.action} passed simulation but reverted in ${hash}`)
    const block = await client.getBlock({ blockNumber: receipt.blockNumber })
    const events = this.decode(receipt)
    const line = this.timeline.add({
      time: block.timestamp,
      block: receipt.blockNumber,
      kind: 'allowed',
      actor: request.actor,
      channel: request.channel,
      action: request.action,
      signers: request.signers,
      role: request.role,
      tx: hash,
      events,
    })
    return { ok: true, line, receipt, events }
  }

  // The rule that would refuse the request, or nothing if it would go through.
  private async simulate(request: Request): Promise<{ error: string; args: unknown[] } | undefined> {
    try {
      await this.chain.client.call({ account: this.chain.relayer, to: request.to, data: request.data })
      return undefined
    } catch (e) {
      const data = revertData(e)
      if (!data || data === '0x') return { error: 'Reverted', args: [] }
      try {
        const decoded = decodeErrorResult({ abi: this.abi, data })
        return { error: decoded.errorName, args: [...(decoded.args ?? [])] }
      } catch {
        return { error: 'Unknown', args: [data] }
      }
    }
  }

  private decode(receipt: TransactionReceipt): ChainEvent[] {
    return parseEventLogs({ abi: this.abi, logs: receipt.logs }).map((log) => ({
      contract: this.names.get(log.address.toLowerCase()) ?? log.address,
      address: log.address,
      name: log.eventName ?? 'Unknown',
      args: (log.args ?? {}) as Record<string, unknown>,
    }))
  }
}

// The revert data a failed call carries, wherever in the error chain the transport put it.
function revertData(e: unknown): Hex | undefined {
  if (!(e instanceof BaseError)) return undefined
  const found = e.walk((inner) => {
    const data = (inner as { data?: unknown }).data
    return typeof data === 'string' && data.startsWith('0x')
  }) as { data?: Hex } | null
  return found?.data
}
