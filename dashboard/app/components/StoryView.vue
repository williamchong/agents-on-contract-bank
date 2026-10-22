<script setup lang="ts">
import { computed } from 'vue'
import { isAlarm, namer, passbook, sentence, type Deployment, type Line } from '~/lib/story'

// One plain sentence per event, refusals included with their reason, newest first; an event that moved
// money leads with its passbook entries, who paid whom and how much. Clicking a line opens it: the
// signers, the role checked, the chain events behind it and its transaction on the block explorer, with
// the balance sheet rows its entry moved highlighted. While an adverse scenario is shown, the refusals and
// incidents since it started are marked. An entity's details show its own lines the same way. See
// docs/architecture.md#story-lines.
const props = defineProps<{
  lines: Line[]
  deployment: Deployment | undefined
  selected?: number
  alarms?: { from?: number; to?: number }
  empty?: string
}>()
const emit = defineEmits<{ select: [seq: number] }>()

// The newest lines only, so a day after day of daily operation does not grow the page without end.
const SHOWN = 300
const shown = computed(() => props.lines.slice(-SHOWN).reverse())
const name = computed(() => (props.deployment ? namer(props.deployment) : (a: string) => a))

function marked(line: Line): boolean {
  const a = props.alarms
  return a?.from !== undefined && line.seq >= a.from && (a.to === undefined || line.seq <= a.to) && isAlarm(line)
}

function select(line: Line) {
  emit('select', line.seq)
}

function entries(line: Line) {
  return props.deployment ? passbook(line, props.deployment, name.value) : []
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
        title="Open for who signed it, the chain events and the transaction"
        @click="select(line)"
        @keydown.enter="select(line)"
      >
        <template v-if="entries(line).length">
          <PassbookEntry v-for="(m, i) in entries(line)" :key="i" :entry="m" />
          <span class="memo">{{ sentence(line) }}</span>
        </template>
        <span v-else class="text"><MoneyText :text="sentence(line)" /></span>
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

li {
  padding: 6px 8px;
  border-bottom: 1px solid var(--line);
  border-left: 3px solid transparent;
  font-size: 13px;
  line-height: 1.4;
  cursor: pointer;
}

li:hover {
  background: var(--chip);
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

.memo {
  display: block;
  color: var(--muted);
  font-size: 12px;
}

.empty {
  color: var(--muted);
  font-size: 13px;
}
</style>
