<script setup lang="ts">
import { computed } from 'vue'
import type { Card } from '~/composables/useControl'
import { SPEEDS } from '~/composables/usePlayback'

// Playing back a recorded run, in one bar across the top: play and pause, the chapter being played, the
// tour's beats and the adverse scenarios, as a list to jump to and as marks on a scrubber across the run's
// story lines, the speed and the bank's clock. See docs/plan.md open question 18.
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
    ? 'Opening'
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
const current = computed(() => props.chapters.findLastIndex((c) => c.from !== undefined && c.from <= props.position))
const nextSpeed = computed(() => SPEEDS[(SPEEDS.indexOf(props.speed) + 1) % SPEEDS.length]!)
const mark = (c: Card) => `${((c.from ?? 0) / Math.max(1, props.total)) * 100}%`

function jump(e: Event) {
  const i = Number((e.target as HTMLSelectElement).value)
  emit('seek', props.chapters[i]?.from ?? 0)
}
</script>

<template>
  <section class="bar" aria-label="Playback">
    <button class="play" :aria-label="playLabel" :title="playLabel" @click="playing ? emit('pause') : emit('play')">
      <span aria-hidden="true">{{ playing ? '❚❚' : '▶' }}</span>
    </button>
    <select class="chapter" aria-label="Chapter" :value="current" @change="jump">
      <option v-if="current < 0" :value="-1" disabled>Opening balance sheet</option>
      <option v-for="(c, i) in chapters" :key="c.from" :value="i">{{ c.title }}</option>
    </select>
    <div class="track">
      <input
        class="scrubber"
        type="range"
        min="0"
        :max="total"
        :value="position"
        aria-label="Position in the run"
        :aria-valuetext="`Line ${position} of ${total}`"
        @input="emit('seek', Number(($event.target as HTMLInputElement).value))"
      />
      <span v-for="c in chapters" :key="c.from" class="mark" :style="{ left: mark(c) }" :title="c.title" />
    </div>
    <button class="speed" :aria-label="`Speed ×${speed}, change to ×${nextSpeed}`" :title="`Speed: ×${speed}`" @click="emit('speed', nextSpeed)">
      ×{{ speed }}
    </button>
    <span class="when">{{ when }}</span>
  </section>
</template>

<style scoped>
.bar {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
  flex: 1;
}

button,
select {
  font: inherit;
  font-size: 13px;
  border-radius: 6px;
  border: 1px solid var(--line);
  background: var(--chip);
  color: var(--ink);
  cursor: pointer;
}

.play {
  width: 34px;
  height: 30px;
  flex: none;
  background: var(--ink);
  color: var(--panel);
  border-color: var(--ink);
}

.chapter {
  padding: 5px 6px;
  max-width: 230px;
  min-width: 0;
}

.track {
  position: relative;
  flex: 1;
  min-width: 80px;
  display: flex;
  align-items: center;
}

.scrubber {
  width: 100%;
  margin: 0;
}

.mark {
  position: absolute;
  top: 50%;
  width: 2px;
  height: 12px;
  margin-top: -6px;
  background: var(--muted);
  opacity: 0.6;
  pointer-events: none;
}

.speed {
  padding: 5px 8px;
  flex: none;
  font-variant-numeric: tabular-nums;
}

.when {
  flex: none;
  font-size: 13px;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}

@media (max-width: 600px) {
  .bar {
    flex-wrap: wrap;
  }

  .track {
    order: 5;
    flex-basis: 100%;
  }

  .when {
    margin-left: auto;
  }
}
</style>
