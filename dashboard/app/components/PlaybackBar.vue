<script setup lang="ts">
import { computed } from 'vue'
import type { Card } from '~/composables/useControl'
import { SPEEDS } from '~/composables/usePlayback'

// Playing back a recorded run: play and pause, the speed, a scrubber across the run's story lines, and its
// chapters, the tour's beats and the adverse scenarios, each a place to jump to. See docs/plan.md open
// question 18.
const props = defineProps<{
  chapters: Card[]
  position: number
  total: number
  playing: boolean
  speed: number
  // Block time of the line shown last, in seconds.
  time: string | undefined
}>()
const emit = defineEmits<{ play: []; pause: []; seek: [to: number]; speed: [speed: number] }>()

// The business day and hour, as the bank keeps them, in Hong Kong.
const when = computed(() =>
  props.time === undefined
    ? 'Opening balance sheet'
    : new Date(Number(props.time) * 1000).toLocaleString('en-HK', {
        timeZone: 'Asia/Hong_Kong',
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        hour: '2-digit',
        minute: '2-digit',
      }),
)
const playLabel = computed(() => {
  if (props.playing) return 'Pause'
  return props.position >= props.total ? 'Play again' : 'Play'
})
const current = computed(() => props.chapters.findLast((c) => c.from !== undefined && c.from <= props.position))
</script>

<template>
  <section aria-label="Playback">
    <h2>Recorded run</h2>
    <div class="row">
      <button @click="playing ? emit('pause') : emit('play')">{{ playLabel }}</button>
      <span class="speed" role="group" aria-label="Speed">
        <button v-for="s in SPEEDS" :key="s" :aria-pressed="speed === s" :class="{ on: speed === s }" @click="emit('speed', s)">×{{ s }}</button>
      </span>
      <span class="when">{{ when }}</span>
    </div>
    <input
      class="scrubber"
      type="range"
      min="0"
      :max="total"
      :value="position"
      aria-label="Position in the run"
      @input="emit('seek', Number(($event.target as HTMLInputElement).value))"
    />
    <p class="where">Line {{ position }} of {{ total }}</p>
    <ol class="chapters">
      <li v-for="c in chapters" :key="c.from">
        <button :class="{ on: c === current }" :aria-current="c === current" @click="emit('seek', c.from ?? 0)">
          {{ c.title }}
        </button>
      </li>
    </ol>
  </section>
</template>

<style scoped>
h2 {
  margin: 0 0 6px;
  font-size: 15px;
}

.row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  margin-bottom: 6px;
}

button {
  font: inherit;
  font-size: 13px;
  padding: 5px 10px;
  border-radius: 6px;
  border: 1px solid var(--line);
  background: var(--chip);
  color: var(--ink);
  cursor: pointer;
}

.speed {
  display: inline-flex;
  gap: 2px;
}

.on {
  background: var(--ink);
  color: var(--panel);
}

.when {
  margin-left: auto;
  font-size: 13px;
  color: var(--muted);
}

.scrubber {
  width: 100%;
  margin: 2px 0;
}

.where {
  margin: 0 0 6px;
  font-size: 12px;
  color: var(--muted);
}

.chapters {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  margin: 0;
  padding: 0;
  list-style: none;
}

.chapters button {
  font-size: 12px;
  padding: 3px 8px;
}
</style>
