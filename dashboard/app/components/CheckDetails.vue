<script setup lang="ts">
import { computed } from 'vue'
import type { BankState } from '~/composables/useBank'
import { checks, type CheckKey } from '~/lib/checks'
import type { Deployment } from '~/lib/story'
import { contractsOf, entity, explorer, type EntityId } from '~/town/entities'

// One of the invariant strip's claims, opened: the claim in full, why it holds, the figures behind it as of
// the latest block, and where to check it on the map and on the block explorer. See
// docs/architecture.md#dashboard.
const props = defineProps<{ id: CheckKey; deployment: Deployment | undefined; state: BankState | undefined }>()
const emit = defineEmits<{ select: [id: EntityId] }>()

const check = computed(() => checks(props.state).find((c) => c.key === props.id))
const base = computed(() => explorer(props.deployment?.chainId))
const contracts = computed(() => (props.deployment && check.value ? contractsOf(check.value.contracts, props.deployment) : []))
const building = computed(() => check.value && entity(check.value.building))
const status = computed(() => {
  const ok = check.value?.ok
  if (ok === undefined) return 'Cannot be told yet'
  return ok ? 'Holds' : 'Broken'
})
</script>

<template>
  <section v-if="check" class="details" aria-label="Check">
    <header>
      <UBadge label="Invariant" variant="subtle" size="sm" class="uppercase" />
      <h2>{{ check.label }}</h2>
    </header>
    <p class="status" :class="{ broken: check.ok === false }">{{ status }}: {{ check.full }}.</p>
    <p class="concept">{{ check.why }}</p>

    <dl class="figures">
      <template v-for="f in check.figures" :key="f.label">
        <dt>{{ f.label }}</dt>
        <dd><MoneyText :text="f.value" /></dd>
      </template>
    </dl>

    <div class="block">
      <h3>Where it is kept</h3>
      <UButton :label="building?.title" variant="outline" size="xs" class="rounded-full" @click="emit('select', check.building)" />
    </div>

    <div class="block chain">
      <h3>On chain</h3>
      <p v-if="state">As of block <ExplorerLink :base="base" kind="block" :value="String(state.block)" /></p>
      <ContractList :contracts="contracts" :base="base" />
    </div>
  </section>
  <p v-else class="empty">Nothing to check until the chain is read.</p>
</template>

<style scoped>
.details {
  font-size: 13px;
}

header {
  display: flex;
  align-items: baseline;
  gap: 8px;
}

h2 {
  margin: 0;
  font-size: 17px;
  font-weight: 600;
}

.status {
  margin: 6px 0 0;
  font-weight: 600;
  color: var(--good);
}

.status.broken {
  color: var(--bad);
}

.concept {
  margin: 6px 0 10px;
  line-height: 1.45;
}

.figures {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 2px 12px;
  margin: 0 0 10px;
  padding: 8px 10px;
  background: var(--chip);
  border-radius: 6px;
}

dt {
  color: var(--muted);
}

dd {
  margin: 0;
  text-align: right;
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}

.block {
  margin-bottom: 12px;
}

h3 {
  margin: 0 0 4px;
  font-size: 13px;
  font-weight: 600;
}

.chain {
  font: 12px/1.6 ui-monospace, monospace;
}

.chain p {
  margin: 0 0 4px;
}

.empty {
  color: var(--muted);
  font-size: 12px;
}
</style>
