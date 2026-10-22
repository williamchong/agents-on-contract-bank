<script setup lang="ts">
import { computed } from 'vue'
import type { BankState } from '~/composables/useBank'
import { checks as checksOf, type CheckKey } from '~/lib/checks'

// The design's headline claims as of the latest block, each in a few words with the full claim on hover and
// what it means one click away, and the block, linked to the block explorer. See docs/architecture.md#dashboard.
const props = defineProps<{ state: BankState | undefined; explorer: string | undefined }>()
const emit = defineEmits<{ open: [key: CheckKey] }>()

const checks = computed(() => checksOf(props.state))

// A check that holds, fails, or cannot be told yet.
function symbol(ok: boolean | undefined): string {
  if (ok === undefined) return '–'
  return ok ? '✓' : '✗'
}

function tone(ok: boolean | undefined): string {
  if (ok === undefined) return 'unknown'
  return ok ? 'ok' : 'broken'
}
</script>

<template>
  <ul class="strip" aria-label="Invariants">
    <li v-for="c in checks" :key="c.key">
      <button :class="tone(c.ok)" :title="c.full" @click="emit('open', c.key)">
        <span aria-hidden="true">{{ symbol(c.ok) }}</span>
        {{ c.label }}
      </button>
    </li>
    <li v-if="state" class="block">
      <ExplorerLink :base="explorer" kind="block" :value="String(state.block)" :label="`Block ${state.block}`" />
    </li>
  </ul>
</template>

<style scoped>
.strip {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 0;
  padding: 0;
  list-style: none;
  font-size: 12px;
}

li {
  white-space: nowrap;
}

button {
  font: inherit;
  padding: 3px 9px;
  border: 0;
  border-radius: 999px;
  background: var(--chip);
  color: var(--ink);
  cursor: pointer;
}

button:hover {
  outline: 1px solid var(--line);
}

@media (max-width: 600px) {
  .strip {
    flex-wrap: nowrap;
    overflow-x: auto;
    flex-basis: 100%;
  }
}

.ok span {
  color: var(--good);
}

.broken {
  background: var(--bad-bg);
  color: var(--bad);
}

.unknown span,
.block {
  color: var(--muted);
}

.block {
  padding: 3px 4px;
  font-variant-numeric: tabular-nums;
}
</style>
