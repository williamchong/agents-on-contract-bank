<script setup lang="ts">
import { computed, ref } from 'vue'
import { namer, sentence, type Deployment, type Line } from '~/lib/story'

// One plain sentence per event, refusals included with their reason, newest first. Under the hood adds the
// transaction and the chain events behind each line. See docs/architecture.md#story-lines.
const props = defineProps<{ lines: Line[]; deployment: Deployment | undefined }>()

const underTheHood = ref(false)
const shown = computed(() => [...props.lines].reverse())
const name = computed(() => (props.deployment ? namer(props.deployment) : (a: string) => a))

function argText(value: unknown): string {
  const s = String(value)
  return /^0x[0-9a-fA-F]{40}$/.test(s) ? name.value(s) : s.length > 18 ? `${s.slice(0, 10)}…` : s
}
</script>

<template>
  <section class="story" aria-label="Story view">
    <header>
      <h2>Story</h2>
      <label><input v-model="underTheHood" type="checkbox" /> Under the hood</label>
    </header>
    <p v-if="!lines.length" class="empty">Nothing has happened yet. Start the daily routines or the tour.</p>
    <ol>
      <li v-for="line in shown" :key="line.seq" :class="line.kind">
        <span class="text">{{ sentence(line) }}</span>
        <div v-if="underTheHood && line.kind !== 'operator'" class="hood">
          <div>channel {{ line.channel }} · block {{ line.block }}<template v-if="line.tx"> · tx {{ line.tx.slice(0, 12) }}…</template></div>
          <div v-if="line.reason">check that failed: {{ line.reason.error }}</div>
          <div v-for="(e, i) in line.events" :key="i">
            {{ e.contract }}.{{ e.name }}
            <span v-for="(v, k) in e.args" :key="k" class="arg">{{ k }}={{ argText(v) }}</span>
          </div>
        </div>
      </li>
    </ol>
  </section>
</template>

<style scoped>
.story {
  display: flex;
  flex-direction: column;
  flex: 0 0 auto;
}

header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 13px;
}

h2 {
  margin: 0 0 6px;
  font-size: 15px;
}

ol {
  margin: 0;
  padding: 0;
  list-style: none;
  max-height: 45vh;
  overflow-y: auto;
}

li {
  padding: 6px 8px;
  border-bottom: 1px solid var(--line);
  font-size: 13px;
  line-height: 1.4;
}

.refused {
  background: var(--bad-bg);
}

.refused .text {
  color: var(--bad);
}

.operator .text {
  color: var(--muted);
  font-style: italic;
}

.hood {
  margin-top: 4px;
  font: 11px/1.5 ui-monospace, monospace;
  color: var(--muted);
  overflow-wrap: anywhere;
}

.arg {
  margin-left: 6px;
}

.empty {
  color: var(--muted);
  font-size: 13px;
}
</style>
