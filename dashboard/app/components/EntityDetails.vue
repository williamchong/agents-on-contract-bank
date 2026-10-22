<script setup lang="ts">
import { computed } from 'vue'
import type { BankState } from '~/composables/useBank'
import type { Deployment, Line } from '~/lib/story'
import { concerns, contractsOf, entity, explorer, figuresOf, parse, staffAt, staffId, staffPresent, type EntityId } from '~/town/entities'
import { toneClass, toneOf } from '~/town/palette'

// A selected building, house or person: what it is, what it holds now and can do, and the story lines it
// took part in, each of which opens, the roles its actions were checked against, and the contracts behind
// it with their source and their addresses on the block explorer. See docs/architecture.md#bank-map.
const props = defineProps<{
  id: EntityId | undefined
  deployment: Deployment | undefined
  state: BankState | undefined
  lines: Line[]
}>()
const emit = defineEmits<{ select: [id: EntityId]; line: [seq: number] }>()

const info = computed(() => (props.id ? entity(props.id) : undefined))
const figures = computed(() => (props.id ? figuresOf(props.id, props.state) : []))
const log = computed(() => {
  const d = props.deployment
  const id = props.id
  return d && id ? props.lines.filter((l) => concerns(id, l, d)) : []
})
const refused = computed(() => log.value.filter((l) => l.kind === 'refused').length)

// The staff working in a building now.
const staff = computed(() => {
  const d = props.deployment
  const p = props.id && parse(props.id)
  if (!d || !p || p.kind !== 'building') return []
  const present = staffPresent(d, props.lines)
  return staffAt(p.id).filter((n) => present.has(n))
})

// The roles the chain checked when this entity acted, and how often.
const roles = computed(() => {
  const counts = new Map<string, number>()
  for (const l of log.value) if (l.role) counts.set(l.role, (counts.get(l.role) ?? 0) + 1)
  return [...counts]
})

const base = computed(() => explorer(props.deployment?.chainId))
const contracts = computed(() => {
  const d = props.deployment
  const id = props.id
  return d && id && info.value ? contractsOf(info.value.contracts, d, id) : []
})
</script>

<template>
  <section class="details" aria-label="Details">
    <p v-if="!info" class="empty">Click a building, a house or a person on the map to see what it is, what it holds and what it has done.</p>
    <template v-else>
      <header>
        <span class="kind">{{ info.kind }}</span>
        <h2 :class="toneClass(toneOf(id))">{{ info.title }}</h2>
      </header>
      <p class="concept">{{ info.concept }}</p>

      <dl v-if="figures.length" class="figures">
        <template v-for="f in figures" :key="f.label">
          <dt>{{ f.label }}</dt>
          <dd><MoneyText :text="f.value" /></dd>
        </template>
      </dl>

      <div v-if="staff.length" class="block">
        <h3>Works here</h3>
        <span class="people">
          <button v-for="n in staff" :key="n" @click="emit('select', staffId(n))">{{ n }}</button>
        </span>
      </div>

      <div class="block">
        <h3>Can</h3>
        <ul class="can">
          <li v-for="c in info.can" :key="c">{{ c }}</li>
        </ul>
      </div>

      <div class="block chain">
        <h3>On chain</h3>
        <p v-if="roles.length">
          Roles checked:
          <span v-for="[r, n] in roles" :key="r" class="tag">{{ r }} ×{{ n }}</span>
        </p>
        <ContractList :contracts="contracts" :base="base" />
      </div>

      <div class="block">
        <h3>
          What it has done
          <small>{{ log.length }} {{ log.length === 1 ? 'line' : 'lines' }}<template v-if="refused">, {{ refused }} refused</template></small>
        </h3>
        <StoryView :lines="log" :deployment="deployment" empty="Nothing yet at this point in the run." @select="emit('line', $event)" />
      </div>
    </template>
  </section>
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
}

.kind {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--muted);
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
}

h3 small {
  font-weight: 400;
  color: var(--muted);
}

.can {
  margin: 0;
  padding-left: 18px;
  line-height: 1.5;
}

.people {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}

.people button {
  font: inherit;
  font-size: 12px;
  padding: 2px 8px;
  border-radius: 999px;
  border: 1px solid var(--line);
  background: var(--chip);
  color: var(--ink);
  cursor: pointer;
}

.chain {
  font: 12px/1.6 ui-monospace, monospace;
}

.chain p {
  margin: 0 0 4px;
}

.tag {
  margin-left: 6px;
  padding: 0 6px;
  border-radius: 4px;
  background: var(--chip);
}

.empty {
  color: var(--muted);
  font-size: 12px;
}
</style>
