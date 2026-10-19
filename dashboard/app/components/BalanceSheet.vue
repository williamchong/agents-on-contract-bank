<script setup lang="ts">
import { computed } from 'vue'
import { Accounts, ratios, type BankState } from '~/composables/useBank'
import { hkd, MIN_CAPITAL, MIN_LIQUIDITY } from '~/lib/money'
import type { Line } from '~/lib/story'

// Assets against deposits and equity, the two ratios against their minimums, and the age of each attested
// figure: the clearing system's statement of the settlement account and the latest cash count. A figure
// that did not match the ledger is marked, and the rows a selected story line moved are highlighted. See
// docs/architecture.md#dashboard.
const props = defineProps<{ state: BankState | undefined; lines: Line[]; moved: number[] }>()

type Account = (typeof Accounts)[number]
interface Row {
  name: string
  account: Account
  amount: bigint
  // How long ago the figure was attested, and whether it matched the ledger.
  attested?: { age: string; matched: boolean }
}

// The latest count at each place, and the newest of them.
const counts = computed(() => {
  const latest = new Map<string, { time: bigint; matched: boolean }>()
  for (const line of props.lines)
    for (const e of line.events)
      if (e.name === 'CashCounted') latest.set(String(e.args.location), { time: BigInt(line.time), matched: e.args.matched === true })
  if (!latest.size) return undefined
  const all = [...latest.values()]
  return { time: all.reduce((t, c) => (c.time > t ? c.time : t), 0n), matched: all.every((c) => c.matched) }
})

function age(since: bigint, now: bigint): string {
  const minutes = Number(now - since) / 60
  if (minutes < 60) return `${Math.max(0, Math.round(minutes))} min`
  if (minutes < 48 * 60) return `${Math.round(minutes / 60)} h`
  return `${Math.round(minutes / 1440)} days`
}

const sheet = computed(() => {
  const s = props.state
  if (!s) return undefined
  const l = s.ledger
  const statement = s.statement && { age: age(s.statement.asOf, s.time), matched: s.statement.matched }
  const count = counts.value && { age: age(counts.value.time, s.time), matched: counts.value.matched }
  const row = (name: string, account: Account, amount: bigint, attested?: Row['attested']): Row => ({ name, account, amount, attested })
  return {
    assets: [
      row('Settlement account', 'Settlement', l.Settlement, statement),
      row('Cash', 'Cash', l.Cash, count),
      row('Liquid securities', 'Securities', l.Securities),
      row('Loans', 'Loans', l.Loans),
      row('Loan loss allowance', 'Allowance', l.Allowance),
    ],
    liabilities: [row('Deposits', 'Deposits', -l.Deposits), row('Equity', 'Equity', -l.Equity)],
    ratios: ratios(l),
  }
})

const movedRows = computed(() => new Set(props.moved.map((i) => Accounts[i])))
</script>

<template>
  <section v-if="sheet" aria-label="Balance sheet">
    <h2>Balance sheet</h2>
    <div class="sides">
      <table>
        <caption>Assets</caption>
        <tr v-for="r in sheet.assets" :key="r.name" :class="{ moved: movedRows.has(r.account), differs: r.attested?.matched === false }">
          <th scope="row">
            {{ r.name }}
            <small v-if="r.attested">{{ r.attested.matched ? 'attested' : 'differs, attested' }} {{ r.attested.age }} ago</small>
          </th>
          <td>{{ hkd(r.amount) }}</td>
        </tr>
        <tr class="total">
          <th scope="row">Total</th>
          <td>{{ hkd(sheet.ratios.totalAssets) }}</td>
        </tr>
      </table>
      <table>
        <caption>Liabilities and equity</caption>
        <tr v-for="r in sheet.liabilities" :key="r.name" :class="{ moved: movedRows.has(r.account) }">
          <th scope="row">{{ r.name }}</th>
          <td>{{ hkd(r.amount) }}</td>
        </tr>
        <tr class="total">
          <th scope="row">Total</th>
          <td>{{ hkd(sheet.ratios.totalLiabilities) }}</td>
        </tr>
      </table>
    </div>
    <p class="note">
      Capital {{ sheet.ratios.capital.toFixed(2) }}% (minimum {{ MIN_CAPITAL }}%) · liquidity {{ sheet.ratios.liquidity.toFixed(2) }}% (minimum
      {{ MIN_LIQUIDITY }}%)
      <template v-if="state?.statement"> · the settlement figure is {{ state.statement.current ? 'current' : 'not current' }}</template>
      <template v-if="moved.length"> · highlighted: the rows the selected line moved</template>
    </p>
  </section>
</template>

<style scoped>
h2 {
  margin: 0 0 6px;
  font-size: 15px;
}

.sides {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
}

caption {
  text-align: left;
  font-weight: 600;
  padding-bottom: 2px;
}

th {
  text-align: left;
  font-weight: 400;
}

td {
  text-align: right;
  font-variant-numeric: tabular-nums;
}

.total {
  border-top: 1px solid var(--line);
  font-weight: 600;
}

small {
  display: block;
  color: var(--muted);
  font-size: 11px;
}

.moved {
  background: var(--chip);
  outline: 2px solid var(--ink);
  outline-offset: -2px;
}

.differs th,
.differs td,
.differs small {
  color: var(--bad);
}

.note {
  margin: 6px 0 0;
  font-size: 12px;
  color: var(--muted);
}
</style>
