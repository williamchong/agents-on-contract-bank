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
const chapterItems = computed(() => [
  ...(current.value < 0 ? [{ label: 'Opening balance sheet', value: -1, disabled: true }] : []),
  ...props.chapters.map((c, i) => ({ label: c.title, value: i })),
])

function jump(i: number) {
  emit('seek', props.chapters[i]?.from ?? 0)
}
</script>

<template>
  <section class="flex min-w-0 flex-1 flex-wrap items-center gap-2.5 sm:flex-nowrap" aria-label="Playback">
    <UButton
      :icon="playing ? 'i-lucide-pause' : 'i-lucide-play'"
      :aria-label="playLabel"
      :title="playLabel"
      @click="playing ? emit('pause') : emit('play')"
    />
    <USelect
      :model-value="current"
      :items="chapterItems"
      aria-label="Chapter"
      class="w-56 min-w-0"
      @update:model-value="jump"
    />
    <div class="relative order-last flex min-w-20 basis-full items-center sm:order-none sm:basis-auto sm:flex-1">
      <USlider
        :model-value="position"
        :min="0"
        :max="total"
        size="sm"
        aria-label="Position in the run"
        :aria-valuetext="`Line ${position} of ${total}`"
        @update:model-value="emit('seek', $event ?? 0)"
      />
      <span
        v-for="c in chapters"
        :key="c.from"
        class="pointer-events-none absolute top-1/2 -mt-1.5 h-3 w-0.5 bg-(--ui-text-muted) opacity-60"
        :style="{ left: mark(c) }"
        :title="c.title"
      />
    </div>
    <UButton
      :label="`×${speed}`"
      variant="soft"
      class="tabular-nums"
      :aria-label="`Speed ×${speed}, change to ×${nextSpeed}`"
      :title="`Speed: ×${speed}`"
      @click="emit('speed', nextSpeed)"
    />
    <span class="ml-auto flex-none text-sm text-muted tabular-nums sm:ml-0">{{ when }}</span>
  </section>
</template>
