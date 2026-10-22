<script setup lang="ts">
import { computed, ref } from 'vue'
import type { SelectItem } from '@nuxt/ui'
import type { Deployment } from '~/lib/story'

// The operator's commands: the guided tour, daily operation, an adverse scenario, time, and a reset to the
// opening balance sheet. Each goes to the control service, which has no authority on chain. See
// docs/architecture.md#control-panel.
const props = defineProps<{
  deployment: Deployment | undefined
  nextBeat: number | undefined
  busy: boolean
  paused: boolean
  pace: number
  daily: boolean
}>()
const emit = defineEmits<{ command: [path: string]; setting: [path: string] }>()

const paces = [
  { label: 'Slow', ms: 1500 },
  { label: 'Normal', ms: 700 },
  { label: 'Fast', ms: 0 },
]
const days = ref<number | null>(1)
// Whole days only; an empty entry jumps nothing.
const jumpDays = computed(() => (days.value == null ? 0 : Math.floor(days.value)))
const DAY_SECONDS = 86_400

// The adverse scenarios in their four groups; a group with none yet is listed empty.
const groups = computed((): SelectItem[][] => {
  const d = props.deployment
  if (!d) return []
  return d.groups.map((name) => {
    const presets = d.presets.filter((p) => p.kind === 'adverse' && p.group === name)
    return [
      { type: 'label', label: name },
      ...(presets.length ? presets.map((p) => ({ label: p.name, value: p.name })) : [{ label: 'None yet', value: `none:${name}`, disabled: true }]),
    ]
  })
})
const beat = computed(() => props.deployment?.beats.find((b) => b.number === props.nextBeat))

// The select shows its prompt again after each choice.
function inject(name: unknown) {
  if (typeof name === 'string') emit('command', `/preset?name=${encodeURIComponent(name)}`)
}
</script>

<template>
  <section class="space-y-1.5" aria-label="Control panel">
    <h2 class="text-[15px] font-semibold">Control panel</h2>
    <div class="flex flex-wrap gap-1.5">
      <UButton
        :label="beat ? `Tour: beat ${beat.number}, ${beat.title}` : 'Tour finished'"
        :disabled="busy || !beat"
        @click="emit('command', '/tour/next')"
      />
      <UButton
        :label="daily ? 'Stop daily operation' : 'Start daily operation'"
        :icon="daily ? 'i-lucide-square' : 'i-lucide-repeat'"
        :aria-pressed="daily"
        variant="outline"
        @click="emit('setting', daily ? '/daily/stop' : '/daily/start')"
      />
    </div>
    <USelect
      :model-value="undefined"
      :items="groups"
      :disabled="busy"
      placeholder="Inject an adverse scenario…"
      aria-label="Inject an adverse scenario"
      class="w-full"
      @update:model-value="inject"
    />
    <div class="flex flex-wrap gap-1.5">
      <UButton
        :label="paused ? 'Resume' : 'Pause'"
        :icon="paused ? 'i-lucide-play' : 'i-lucide-pause'"
        variant="outline"
        @click="emit('setting', paused ? '/resume' : '/pause')"
      />
      <UFieldGroup role="group" aria-label="Speed">
        <UButton
          v-for="p in paces"
          :key="p.ms"
          :label="p.label"
          :aria-pressed="pace === p.ms"
          :variant="pace === p.ms ? 'solid' : 'outline'"
          @click="emit('setting', `/pace?ms=${p.ms}`)"
        />
      </UFieldGroup>
    </div>
    <div class="flex flex-wrap gap-1.5">
      <UButton label="+1 hour" variant="outline" :disabled="busy" @click="emit('command', '/time/advance?seconds=3600')" />
      <UFieldGroup>
        <UInputNumber v-model="days" :min="1" :max="365" class="w-24" aria-label="Days to jump" />
        <UButton
          :label="`Jump ${jumpDays === 1 ? 'a day' : `${jumpDays} days`}`"
          variant="outline"
          :disabled="busy || jumpDays < 1"
          @click="emit('command', `/time/advance?seconds=${jumpDays * DAY_SECONDS}`)"
        />
      </UFieldGroup>
      <UButton label="Close the day" variant="outline" :disabled="busy" @click="emit('command', '/time/end-of-day')" />
      <UButton label="Reset" color="error" variant="soft" class="ml-auto" :disabled="busy" @click="emit('command', '/reset')" />
    </div>
  </section>
</template>
