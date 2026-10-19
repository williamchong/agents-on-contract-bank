<script setup lang="ts">
import { computed } from 'vue'
import { ratios, type BankState } from '~/composables/useBank'
import { hkd, MIN_CAPITAL, MIN_LIQUIDITY } from '~/lib/money'

// Assets against deposits and equity, the two ratios against their minimums, and the age of the clearing
// system's latest statement, all as the ledger reports them. See docs/architecture.md#dashboard.
const props = defineProps<{ state: BankState | undefined }>()

const sheet = computed(() => {
  const s = props.state
  if (!s) return undefined
  const l = s.ledger
  return {
    assets: [
      ['Settlement account', l.Settlement],
      ['Cash', l.Cash],
      ['Liquid securities', l.Securities],
      ['Loans', l.Loans],
      ['Loan loss allowance', l.Allowance],
    ] as [string, bigint][],
    liabilities: [
      ['Deposits', -l.Deposits],
      ['Equity', -l.Equity],
    ] as [string, bigint][],
    ratios: ratios(l),
  }
})
</script>

<template>
  <section v-if="sheet" aria-label="Balance sheet">
    <h2>Balance sheet</h2>
    <div class="sides">
      <table>
        <caption>Assets</caption>
        <tr v-for="[name, amount] in sheet.assets" :key="name">
          <th scope="row">{{ name }}</th>
          <td>{{ hkd(amount) }}</td>
        </tr>
        <tr class="total">
          <th scope="row">Total</th>
          <td>{{ hkd(sheet.ratios.totalAssets) }}</td>
        </tr>
      </table>
      <table>
        <caption>Liabilities and equity</caption>
        <tr v-for="[name, amount] in sheet.liabilities" :key="name">
          <th scope="row">{{ name }}</th>
          <td>{{ hkd(amount) }}</td>
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
      <template v-if="state?.statement">
        · settlement attested {{ state.statement.current ? 'and current' : 'but not current' }}
      </template>
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

.note {
  margin: 6px 0 0;
  font-size: 12px;
  color: var(--muted);
}
</style>
