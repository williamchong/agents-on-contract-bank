// A recorded run, played back with no chain or control service: the story up to a point in the run, the
// scenario card showing there, and the bank's state at that line's block, read during the run by
// `pnpm record`. Playback moves one story line at a time, so the waits of a time lock or a night take no
// longer than any other step. See docs/plan.md open question 18.

import { computed, onScopeDispose, ref, shallowRef } from 'vue'
import { parseBankState, type BankState } from '@bank/services/state'
import type { Card } from '~/composables/useControl'
import type { Deployment, Line } from '~/lib/story'

interface Recording {
  deployment: Deployment
  opening: string
  lines: Line[]
  cards: Card[]
  states: unknown[]
}

// The control service's default pace, at ×1.
const STEP_MS = 700
export const SPEEDS = [1, 2, 4, 8]

export function usePlayback(url: string) {
  const deployment = shallowRef<Deployment>()
  const all = shallowRef<Line[]>([])
  const chapters = shallowRef<Card[]>([])
  const states = new Map<string, BankState>()
  let opening = ''
  // How many of the run's lines are shown.
  const position = ref(0)
  const playing = ref(false)
  const speed = ref(1)
  // Moves on at each seek, so the bank map takes the lines jumped over as history, not as traffic.
  const epoch = ref(0)
  const error = ref<string>()
  let timer: ReturnType<typeof setTimeout> | undefined

  const lines = computed(() => all.value.slice(0, position.value))
  const state = computed(() => states.get(lines.value.at(-1)?.block ?? opening))
  // The card showing at this point: the last one started, still running until its last line is shown.
  const card = computed<Card | undefined>(() => {
    const seq = lines.value.at(-1)?.seq ?? 0
    const shown = chapters.value.findLast((c) => c.from !== undefined && c.from <= seq)
    if (!shown || seq >= (shown.to ?? 0)) return shown
    return { ...shown, status: 'running', checks: [], error: undefined }
  })

  async function load() {
    try {
      const res = await fetch(url)
      if (!res.ok) throw new Error('No recording to play: make one with `pnpm record`.')
      const recording: Recording = await res.json()
      for (const raw of recording.states) {
        const s = parseBankState(raw)
        states.set(String(s.block), s)
      }
      const unread = recording.lines.find((l) => !states.has(String(l.block)))
      if (unread) throw new Error(`The recording has no state for block ${unread.block}: record it again.`)
      opening = String(recording.opening)
      all.value = recording.lines
      chapters.value = recording.cards
      deployment.value = recording.deployment
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    }
  }

  function schedule() {
    clearTimeout(timer)
    if (playing.value) timer = setTimeout(step, STEP_MS / speed.value)
  }

  function step() {
    position.value++
    if (position.value >= all.value.length) playing.value = false
    schedule()
  }

  function play() {
    if (position.value >= all.value.length) seek(0)
    if (!all.value.length) return
    playing.value = true
    schedule()
  }

  function pause() {
    playing.value = false
    clearTimeout(timer)
  }

  function seek(to: number) {
    position.value = Math.min(all.value.length, Math.max(0, to))
    epoch.value++
    schedule()
  }

  function setSpeed(s: number) {
    speed.value = s
    schedule()
  }

  void load()
  onScopeDispose(() => clearTimeout(timer))
  return { deployment, lines, card, state, error, chapters, position, total: computed(() => all.value.length), playing, speed, epoch, play, pause, seek, setSpeed }
}
