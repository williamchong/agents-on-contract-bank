<script setup lang="ts">
import { computed } from 'vue'
import { ratios, type BankState } from '~/composables/useBank'
import { MIN_CAPITAL, MIN_LIQUIDITY } from '~/lib/money'

// The design's headline claims as of the latest block, each with the milestone that brings it. See
// docs/architecture.md#dashboard.
const props = defineProps<{ state: BankState | undefined }>()

const checks = computed(() => {
  const s = props.state
  if (!s) return []
  const split = s.cash.vault + s.cash.drawer + s.cash.atm + s.cash.replacementDrawer
  const r = ratios(s.ledger)
  return [
    { label: 'The books balance', ok: s.booksBalance },
    { label: 'Cash in the vault, drawers and ATM is the ledger’s cash', ok: split === s.ledger.Cash },
    {
      label: s.statement ? `Clearing statement ${s.statement.matched ? 'matches' : 'does not match'} the ledger` : 'No clearing statement yet',
      ok: s.statement ? s.statement.matched : undefined,
    },
    { label: `Capital ${r.capital.toFixed(2)}% (minimum ${MIN_CAPITAL}%)`, ok: r.capital >= MIN_CAPITAL },
    { label: `Liquidity ${r.liquidity.toFixed(2)}% (minimum ${MIN_LIQUIDITY}%)`, ok: r.liquidity >= MIN_LIQUIDITY },
  ]
})

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
    <li v-for="c in checks" :key="c.label" :class="tone(c.ok)">
      <span aria-hidden="true">{{ symbol(c.ok) }}</span>
      {{ c.label }}
    </li>
    <li v-if="state" class="block">Block {{ state.block }}</li>
  </ul>
</template>

<style scoped>
.strip {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: 0;
  padding: 8px 16px;
  list-style: none;
  background: var(--panel);
  border-bottom: 1px solid var(--line);
  font-size: 13px;
}

li {
  padding: 3px 10px;
  border-radius: 999px;
  background: var(--chip);
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
  margin-left: auto;
  background: none;
}
</style>
