// The control service: the run's timeline as it grows, the scenario card, and the operator's commands. It
// runs on the operator's machine beside the local chain; start it with `pnpm demo`. See docs/plan.md open
// question 23.

import { onScopeDispose, ref, shallowRef } from 'vue'
import type { Deployment, Line } from '~/lib/story'

export interface Card {
  title: string
  kind: 'routine' | 'adverse' | 'tour'
  control?: string
  // The building on the bank map an adverse scenario concerns, which the map marks while it is shown.
  building?: string
  pointAt?: string
  claim?: string
  waitsFor?: string[]
  status: 'running' | 'passed' | 'failed'
  checks: { name: string; pass: boolean; detail?: string }[]
  error?: string
}

const base = 'http://127.0.0.1:8546'

export function useControl() {
  const deployment = shallowRef<Deployment>()
  const lines = ref<Line[]>([])
  const card = shallowRef<Card>()
  const nextBeat = ref<number>()
  const paused = ref(false)
  const pace = ref(700)
  const busy = ref(false)
  const error = ref<string>()
  let source: EventSource | undefined

  // Loads the run as it stands. Called each time the event stream opens, so a control service that was
  // restarted, with a new bank and a new story, replaces the old one.
  async function load() {
    try {
      // The history arrives before the deployment, so the map takes it as history, not as traffic.
      const [d, state] = await Promise.all([(await fetch(`${base}/deployment`)).json(), (await fetch(`${base}/state`)).json()])
      lines.value = state.lines
      deployment.value = d
      card.value = state.card
      apply(state)
      error.value = undefined
    } catch {
      error.value = 'No bank to show yet: start the chain with `pnpm hardhat node` and the bank with `pnpm demo`.'
    }
  }

  function listen() {
    source = new EventSource(`${base}/events`)
    source.onopen = () => void load()
    source.onerror = () => (error.value = 'The control service is not answering: is `pnpm demo` running?')
    source.onmessage = (m) => {
      const message = JSON.parse(m.data)
      // A line already loaded with the run's state is not added twice.
      const lastSeq = lines.value[lines.value.length - 1]?.seq ?? 0
      if (message.type === 'line' && message.line.seq > lastSeq) lines.value.push(message.line)
      if (message.type === 'card') card.value = { ...message.card }
      // A reset opens a fresh bank, at new addresses.
      if (message.type === 'reset') {
        lines.value = []
        card.value = undefined
        void fetch(`${base}/deployment`).then(async (r) => (deployment.value = await r.json()))
      }
      if (message.type !== 'line') void refreshBeat()
    }
  }

  function apply(state: { nextBeat?: number; paused: boolean; pace: number }) {
    nextBeat.value = state.nextBeat
    paused.value = state.paused
    pace.value = state.pace
  }

  async function refreshBeat() {
    apply(await (await fetch(`${base}/status`)).json())
  }

  // Pausing, resuming and the pace act at once, even while a run holds the other commands.
  async function setting(path: string) {
    try {
      const res = await fetch(`${base}${path}`, { method: 'POST' })
      const body = await res.json()
      if (!res.ok) error.value = body.error
      else apply(body)
    } catch {
      error.value = 'The control service is not answering: is `pnpm demo` running?'
    }
  }

  // Sends an operator command; the run's lines arrive as they happen.
  async function command(path: string) {
    busy.value = true
    try {
      const res = await fetch(`${base}${path}`, { method: 'POST' })
      const body = await res.json()
      if (!res.ok) error.value = body.error
      else error.value = undefined
      await refreshBeat()
    } catch {
      error.value = 'The control service is not answering: is `pnpm demo` running?'
    } finally {
      busy.value = false
    }
  }

  listen()
  onScopeDispose(() => source?.close())
  return { deployment, lines, card, nextBeat, paused, pace, busy, error, command, setting }
}
