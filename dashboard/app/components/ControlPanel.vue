<script setup lang="ts">
import { computed } from 'vue'
import type { Deployment } from '~/lib/story'

// The operator's commands: the guided tour, the daily routines, an adverse scenario, time, and a reset to
// the opening balance sheet. Each goes to the control service, which has no authority on chain. See
// docs/architecture.md#control-panel.
const props = defineProps<{ deployment: Deployment | undefined; nextBeat: number | undefined; busy: boolean }>()
const emit = defineEmits<{ command: [path: string] }>()

const scenarios = computed(() => props.deployment?.presets.filter((p) => p.kind === 'adverse') ?? [])
const beat = computed(() => props.deployment?.beats.find((b) => b.number === props.nextBeat))

function inject(event: Event) {
  const select = event.target as HTMLSelectElement
  if (select.value) emit('command', `/preset?name=${encodeURIComponent(select.value)}`)
  select.value = ''
}
</script>

<template>
  <section aria-label="Control panel">
    <h2>Control panel</h2>
    <div class="row">
      <button :disabled="busy || !beat" @click="emit('command', '/tour/next')">
        {{ beat ? `Tour: beat ${beat.number}, ${beat.title}` : 'Tour finished' }}
      </button>
      <button :disabled="busy" @click="emit('command', '/daily')">Run the daily routines</button>
    </div>
    <div class="row">
      <select
        :disabled="busy"
        aria-label="Inject an adverse scenario"
        @change="inject"
      >
        <option value="">Inject an adverse scenario…</option>
        <option v-for="s in scenarios" :key="s.name" :value="s.name">{{ s.name }}</option>
      </select>
    </div>
    <div class="row">
      <button :disabled="busy" @click="emit('command', '/time/advance?seconds=3600')">+1 hour</button>
      <button :disabled="busy" @click="emit('command', '/time/end-of-day')">Close the day</button>
      <button :disabled="busy" class="reset" @click="emit('command', '/reset')">Reset</button>
    </div>
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
  gap: 6px;
  margin-bottom: 6px;
}

button,
select {
  font: inherit;
  font-size: 13px;
  padding: 5px 10px;
  border-radius: 6px;
  border: 1px solid var(--line);
  background: var(--chip);
  color: var(--ink);
  cursor: pointer;
}

button:disabled,
select:disabled {
  opacity: 0.5;
  cursor: default;
}

.reset {
  margin-left: auto;
}
</style>
