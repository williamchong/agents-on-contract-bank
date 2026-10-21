<script setup lang="ts">
import { computed } from 'vue'
import { isAlarm, namer, passbook, sentence, type Deployment, type Line } from '~/lib/story'
import { explorer } from '~/town/entities'

// One plain sentence per event, refusals included with their reason, newest first; an event that moved
// money leads with its passbook entries, who paid whom and how much. Under the hood adds the
// signers, the role checked, the transaction and the chain events behind each line. Selecting a line
// shows the balance sheet rows its entry moved; while an adverse scenario is shown, the refusals and
// incidents since it started are marked. An entity's details show its own lines the same way. See
// docs/architecture.md#story-lines.
const props = defineProps<{
  lines: Line[]
  deployment: Deployment | undefined
  selected?: number
  alarms?: { from?: number; to?: number }
  underTheHood?: boolean
  empty?: string
}>()
const emit = defineEmits<{ select: [seq: number | undefined] }>()

const txBase = computed(() => explorer(props.deployment?.chainId))
// The newest lines only, so a day after day of daily operation does not grow the page without end.
const SHOWN = 300
const shown = computed(() => props.lines.slice(-SHOWN).reverse())
const name = computed(() => (props.deployment ? namer(props.deployment) : (a: string) => a))

function marked(line: Line): boolean {
  const a = props.alarms
  return a?.from !== undefined && line.seq >= a.from && (a.to === undefined || line.seq <= a.to) && isAlarm(line)
}

function select(line: Line) {
  emit('select', line.seq === props.selected ? undefined : line.seq)
}

function entries(line: Line) {
  return props.deployment ? passbook(line, props.deployment, name.value) : []
}

function argText(value: unknown): string {
  const s = String(value)
  return /^0x[0-9a-fA-F]{40}$/.test(s) ? name.value(s) : s.length > 18 ? `${s.slice(0, 10)}…` : s
}
</script>

<template>
  <section class="story" aria-label="Story view">
    <p v-if="!lines.length" class="empty">{{ empty ?? 'Nothing has happened yet.' }}</p>
    <ol>
      <li
        v-for="line in shown"
        :key="line.seq"
        :class="[line.kind, { selected: line.seq === selected, alarm: marked(line) }]"
        :aria-selected="line.seq === selected"
        tabindex="0"
        @click="select(line)"
        @keydown.enter="select(line)"
      >
        <template v-if="entries(line).length">
          <div v-for="(m, i) in entries(line)" :key="i" class="entry">
            <span class="party">{{ m.from }}</span>
            <span class="arrow" aria-hidden="true">→</span>
            <span class="hidden">to</span>
            <span class="party">{{ m.to }}</span>
            <span class="money">{{ m.amount }}</span>
          </div>
          <span class="memo">{{ sentence(line) }}</span>
        </template>
        <span v-else class="text"><MoneyText :text="sentence(line)" /></span>
        <div v-if="underTheHood && line.kind !== 'operator'" class="hood">
          <div v-if="line.signers?.length">
            signed by {{ line.signers.join(', ') }}<template v-if="line.role"> · role checked: {{ line.role }}</template>
          </div>
          <div>channel {{ line.channel }} · block {{ line.block }}<template v-if="line.tx">
              · tx
              <a v-if="txBase" :href="`${txBase}/tx/${line.tx}`" target="_blank" rel="noopener" @click.stop>{{ line.tx.slice(0, 12) }}…</a>
              <span v-else :title="line.tx">{{ line.tx.slice(0, 12) }}…</span>
            </template></div>
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

ol {
  margin: 0;
  padding: 0;
  list-style: none;
}

.hood a {
  color: inherit;
}

li {
  padding: 6px 8px;
  border-bottom: 1px solid var(--line);
  border-left: 3px solid transparent;
  font-size: 13px;
  line-height: 1.4;
  cursor: pointer;
}

.selected {
  border-left-color: var(--ink);
  background: var(--chip);
}

.alarm {
  border-left-color: var(--bad);
  font-weight: 600;
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

/* A line that moved money reads as a passbook entry: who paid whom and how much, with what happened below. */
.entry {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr) auto;
  gap: 8px;
  align-items: baseline;
  font-variant-numeric: tabular-nums;
}

.party {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.arrow {
  color: var(--muted);
}

.entry .money {
  text-align: right;
  font-weight: 600;
}

.hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
}

.memo {
  display: block;
  color: var(--muted);
  font-size: 12px;
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
