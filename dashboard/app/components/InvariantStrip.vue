<script setup lang="ts">
import { computed } from 'vue'
import { ratios, type BankState } from '~/composables/useBank'
import { MIN_CAPITAL, MIN_LIQUIDITY } from '~/lib/money'

// The design's headline claims as of the latest block, each in a few words with the full claim on hover.
// Under the hood adds the block. See docs/architecture.md#dashboard.
const props = defineProps<{ state: BankState | undefined; underTheHood?: boolean }>()

const checks = computed(() => {
  const s = props.state
  if (!s) return []
  const split = s.cash.vault + s.cash.drawer + s.cash.atm + s.cash.replacementDrawer
  const r = ratios(s.ledger)
  return [
    { label: s.booksBalance ? 'Books balance' : 'Books do not balance', full: 'Assets equal deposits and equity in the general ledger', ok: s.booksBalance },
    { label: 'Cash adds up', full: 'Cash in the vault, drawers and ATM is the ledger’s cash', ok: split === s.ledger.Cash },
    {
      label: s.statement ? `Clearing ${s.statement.matched ? 'matches' : 'differs'}` : 'No clearing statement',
      full: s.statement
        ? `The clearing system’s statement of the settlement account ${s.statement.matched ? 'matches' : 'does not match'} the ledger`
        : 'No statement from the clearing system yet',
      ok: s.statement ? s.statement.matched : undefined,
    },
    { label: `Capital ${r.capital.toFixed(1)}%`, full: `Capital ratio ${r.capital.toFixed(2)}%, minimum ${MIN_CAPITAL}%`, ok: r.capital >= MIN_CAPITAL },
    { label: `Liquidity ${r.liquidity.toFixed(1)}%`, full: `Liquidity ratio ${r.liquidity.toFixed(2)}%, minimum ${MIN_LIQUIDITY}%`, ok: r.liquidity >= MIN_LIQUIDITY },
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
    <li v-for="c in checks" :key="c.full" :class="tone(c.ok)" :title="c.full">
      <span aria-hidden="true">{{ symbol(c.ok) }}</span>
      {{ c.label }}
    </li>
    <li v-if="state && underTheHood" class="block">Block {{ state.block }}</li>
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
  padding: 3px 9px;
  white-space: nowrap;
  cursor: help;
  border-radius: 999px;
  background: var(--chip);
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
  background: none;
  font-variant-numeric: tabular-nums;
}
</style>
