// The control service: holds the bank, runs on the operator's machine beside the local chain, and serves
// the dashboard the run's timeline as it grows and the operator's controls: the daily routines, an adverse
// scenario, the guided tour's next beat, closing the day or moving time on, and resetting the run to the
// opening balance sheet. It has no authority on chain; everything it starts acts through the actors' own
// accounts and the submission service. It listens on the local machine only. See open question 23 in
// docs/plan.md and the control panel in docs/architecture.md.

import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { deployBank, Staff, type Bank } from './bank.ts'
import { drawer, Holders } from './books.ts'
import { advance, type Chain } from './chain.ts'
import { Clearing } from './clearing.ts'
import { locationId, places } from './operations.ts'
import { closeDay, operator, presets, type Check, type Context } from './scenarios.ts'
import { Timeline, toJson, type Line } from './timeline.ts'
import { beats } from './tour.ts'

// What the scenario card shows while a preset or a tour beat runs, and its score once it ends.
export interface Card {
  title: string
  kind: 'routine' | 'adverse' | 'tour'
  control?: string
  building?: string
  pointAt?: string
  claim?: string
  waitsFor?: string[]
  status: 'running' | 'passed' | 'failed'
  checks: Check[]
  error?: string
}

type Message = { type: 'line'; line: Line } | { type: 'card'; card: Card } | { type: 'reset' }

export class Control {
  private readonly chain: Chain
  private bank!: Bank
  private clearing!: Clearing
  private readonly timeline = new Timeline()
  // Slow enough by default for an audience to see each step, a waiting item before it is approved; kept
  // across a reset.
  private pace = 700
  // While a bank is being opened, its setting up is not part of the story, so nothing is sent.
  private opening = false
  private card: Card | undefined
  private nextBeat = 0
  private busy = false
  private readonly clients = new Set<ServerResponse>()

  constructor(chain: Chain) {
    this.chain = chain
  }

  // Opens the bank at the opening balance sheet: a fresh deployment, whose setting up is not part of the
  // story the dashboard tells.
  async open(): Promise<void> {
    this.opening = true
    try {
      this.bank = await deployBank(this.chain, this.timeline)
    } finally {
      this.opening = false
    }
    this.timeline.clear()
    this.bank.submission.pace = this.pace
    this.clearing = await Clearing.open(this.bank)
  }

  async listen(): Promise<void> {
    this.timeline.subscribe((line) => this.send({ type: 'line', line }))
    await this.open()
  }

  // What the dashboard needs to draw the bank: the contracts, who is who, and what it can run.
  async deployment() {
    const bank = this.bank
    return {
      chainId: this.chain.chainId,
      contracts: bank.contracts,
      customers: Object.fromEntries(Holders.map((n) => [n, bank.account(n)])),
      staff: Object.fromEntries([...Object.keys(Staff), 'replacement teller', 'ATM'].map((n) => [n, bank.account(n)])),
      cash: {
        ...Object.fromEntries(await Promise.all(Object.entries(places(bank)).map(async ([k, at]) => [k, await locationId(bank, at)]))),
        replacementDrawer: await locationId(bank, drawer(bank.account('replacement teller'))),
      },
      presets: presets.map((p) => ({ name: p.name, kind: p.kind, control: p.control })),
      beats: beats.map(({ number, title, pointAt, claim }) => ({ number, title, pointAt, claim })),
    }
  }

  state() {
    const s = this.bank.submission
    return { lines: this.bank.timeline.lines, card: this.card, nextBeat: beats[this.nextBeat]?.number, paused: s.isPaused, pace: s.pace }
  }

  // Pausing holds the run before its next request; it does not take the command lock, so the operator
  // can pause a scenario while it runs.
  pause(): void {
    if (this.bank.submission.isPaused) return
    this.bank.submission.pause()
    this.note('pause the run')
  }

  resume(): void {
    if (!this.bank.submission.isPaused) return
    this.bank.submission.resume()
    this.note('resume the run')
  }

  // How long each request waits, so the operator can slow a run for an audience or let it go at full speed.
  setPace(ms: number): void {
    if (!Number.isFinite(ms) || ms < 0 || ms > MAX_PACE) throw new Error(`A pace is between 0 and ${MAX_PACE} ms`)
    this.pace = ms
    this.bank.submission.pace = ms
  }

  // An operator line written outside a command, which must never bring the service down.
  private note(action: string): void {
    operator(this.bank, action).catch(() => {})
  }

  runPreset(name: string): Promise<Card> {
    const preset = presets.find((p) => p.name === name)
    if (!preset) throw new Error(`No preset called ${name}`)
    const { control, building, waitsFor } = preset
    const card: Card = { title: preset.name, kind: preset.kind, status: 'running', checks: [], ...{ control, building, waitsFor } }
    return this.run(`run ${preset.kind === 'adverse' ? 'the scenario' : 'the routine'}: ${preset.name}`, card, (ctx) => preset.run(ctx))
  }

  // Every daily routine in turn; each closes its own day.
  runDaily(): Promise<Card> {
    const routines = presets.filter((p) => p.kind === 'routine')
    const card: Card = { title: 'Daily operation', kind: 'routine', status: 'running', checks: [] }
    return this.run('run daily operation', card, async (ctx) => {
      const checks: Check[] = []
      for (const routine of routines) checks.push(...(await routine.run(ctx)))
      return checks
    })
  }

  nextTourBeat(): Promise<Card> {
    const beat = beats[this.nextBeat]
    if (!beat) throw new Error('The tour has run all its beats; reset to start it again')
    const card: Card = { title: `Beat ${beat.number}: ${beat.title}`, kind: 'tour', pointAt: beat.pointAt, claim: beat.claim, status: 'running', checks: [] }
    // The beat is used up only once it runs, not when the service was busy and turned it away.
    return this.run(`move the tour on to beat ${beat.number}: ${beat.title}`, card, (ctx) => {
      this.nextBeat++
      return beat.run(ctx)
    })
  }

  // Closes the day, or moves block time on: every time lock, limit and signature window moves with it.
  async time(action: 'end of day' | 'advance', seconds = 3600n): Promise<void> {
    if (seconds <= 0n) throw new Error('Time only moves forward')
    await this.exclusive(async () => {
      if (action === 'end of day') {
        await closeDay(this.context())
      } else {
        await operator(this.bank, `move time on by ${seconds % 86_400n === 0n ? `${seconds / 86_400n} days` : `${seconds / 60n} minutes`}`)
        await advance(this.chain, seconds)
      }
    })
  }

  // Back to the opening balance sheet, as at the start of a demo, by opening a fresh bank rather than
  // reverting the chain: block numbers then only rise, and nothing that reads the chain by block can see
  // a block from before a revert.
  async reset(): Promise<void> {
    await this.exclusive(async () => {
      await this.open()
      this.card = undefined
      this.nextBeat = 0
      this.send({ type: 'reset' })
    })
  }

  private context(): Context {
    return { bank: this.bank, clearing: this.clearing }
  }

  private async run(command: string, card: Card, body: (ctx: Context) => Promise<Check[]>): Promise<Card> {
    return this.exclusive(async () => {
      await operator(this.bank, command)
      this.card = card
      this.send({ type: 'card', card })
      try {
        card.checks = await body(this.context())
        card.status = card.checks.every((c) => c.pass) ? 'passed' : 'failed'
      } catch (e) {
        card.status = 'failed'
        card.error = e instanceof Error ? e.message : String(e)
      }
      this.send({ type: 'card', card })
      return card
    })
  }

  // One command at a time, as the chain's state moves under each.
  private async exclusive<T>(body: () => Promise<T>): Promise<T> {
    if (this.busy) throw new Busy()
    this.busy = true
    try {
      return await body()
    } finally {
      this.busy = false
    }
  }

  // Server-sent events

  subscribe(res: ServerResponse, origin: string | undefined): void {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive', ...corsFor(origin) })
    res.write(': connected\n\n')
    this.clients.add(res)
    res.on('close', () => this.clients.delete(res))
  }

  private send(message: Message): void {
    if (this.opening) return
    const data = `data: ${toJson(message)}\n\n`
    for (const client of this.clients) client.write(data)
  }
}

const MAX_PACE = 10_000

class Busy extends Error {
  constructor() {
    super('Another command is still running')
  }
}

// Only the dashboard on the local machine may read or drive the control service: a page from anywhere
// else could otherwise send it a command, as a plain POST needs no preflight.
const dashboardOrigins = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/

function corsFor(origin: string | undefined) {
  return {
    'access-control-allow-origin': origin && dashboardOrigins.test(origin) ? origin : 'http://localhost:3000',
    'access-control-allow-methods': 'GET, POST',
    'access-control-allow-headers': 'content-type',
    vary: 'origin',
  }
}

// Serves the control service on the local machine only.
export function serve(control: Control, port = 8546) {
  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    const origin = req.headers.origin
    const reply = (status: number, body: unknown) => {
      res.writeHead(status, { 'content-type': 'application/json', ...corsFor(origin) })
      res.end(toJson(body))
    }
    try {
      if (origin && !dashboardOrigins.test(origin)) return reply(403, { error: 'Only the dashboard on this machine may use the control service' })
      if (req.method === 'OPTIONS') return reply(204, '')
      if (req.method === 'GET' && url.pathname === '/deployment') return reply(200, await control.deployment())
      if (req.method === 'GET' && url.pathname === '/state') return reply(200, control.state())
      if (req.method === 'GET' && url.pathname === '/events') return control.subscribe(res, origin)
      if (req.method !== 'POST') return reply(404, { error: 'Not found' })
      switch (url.pathname) {
        case '/preset':
          return reply(200, await control.runPreset(url.searchParams.get('name') ?? ''))
        case '/daily':
          return reply(200, await control.runDaily())
        case '/tour/next':
          return reply(200, await control.nextTourBeat())
        case '/time/end-of-day':
          await control.time('end of day')
          return reply(200, control.state())
        case '/time/advance':
          await control.time('advance', BigInt(url.searchParams.get('seconds') ?? '3600'))
          return reply(200, control.state())
        case '/reset':
          await control.reset()
          return reply(200, control.state())
        case '/pause':
          control.pause()
          return reply(200, control.state())
        case '/resume':
          control.resume()
          return reply(200, control.state())
        case '/pace':
          control.setPace(Number(url.searchParams.get('ms') ?? Number.NaN))
          return reply(200, control.state())
        default:
          return reply(404, { error: 'Not found' })
      }
    } catch (e) {
      reply(e instanceof Busy ? 409 : 400, { error: e instanceof Error ? e.message : String(e) })
    }
  })
  server.listen(port, '127.0.0.1')
  return server
}
