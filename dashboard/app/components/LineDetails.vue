<script setup lang="ts">
import { computed } from 'vue'
import { Accounts } from '~/composables/useBank'
import { hkd } from '~/lib/money'
import { ledgerLines, namer, passbook, reasonOf, type Deployment, type Line } from '~/lib/story'
import { entity, explorer, type EntityId } from '~/town/entities'
import { involved } from '~/town/focus'
import { addressToner, toneOf } from '~/town/palette'

// A story line opened: what happened in plain words, who signed it and the role checked, the places on the
// map it involved and the ledger entry it posted, then the chain events behind it, each linked to the block
// explorer: the transaction, its block, every contract that emitted an event and every address in one. See
// docs/architecture.md#story-lines.
const props = defineProps<{ seq: number; deployment: Deployment | undefined; lines: Line[] }>()
const emit = defineEmits<{ select: [id: EntityId]; sheet: [] }>()

const line = computed(() => props.lines.find((l) => l.seq === props.seq))
const base = computed(() => explorer(props.deployment?.chainId))
const name = computed(() => (props.deployment ? namer(props.deployment) : (a: string) => a))

const entries = computed(() => {
  const d = props.deployment
  return line.value && d ? passbook(line.value, d, name.value, addressToner(d)) : []
})
const places = computed(() => {
  const d = props.deployment
  if (!d || !line.value) return []
  return [...involved(d, line.value)].flatMap((id) => {
    const e = entity(id)
    return e ? [{ id, title: e.title, tone: toneOf(id) }] : []
  })
})
// The account the actor acted from, which their keys signed for.
const account = computed(() => {
  const d = props.deployment
  const actor = line.value?.actor
  return d && actor ? (d.staff[actor] ?? d.customers[actor]) : undefined
})
const ledger = computed(() => (line.value ? ledgerLines(line.value).map((l) => ({ account: Accounts[l.account], amount: hkd(l.amount) })) : []))
const kinds: Record<Line['kind'], { label: string; color: 'success' | 'error' | 'neutral' }> = {
  allowed: { label: 'Allowed', color: 'success' },
  refused: { label: 'Refused', color: 'error' },
  operator: { label: 'Operator', color: 'neutral' },
}

const when = computed(() =>
  line.value
    ? new Date(Number(line.value.time) * 1000).toLocaleString('en-HK', { timeZone: 'Asia/Hong_Kong', dateStyle: 'medium', timeStyle: 'short' })
    : '',
)

const isAddress = (v: unknown): v is string => typeof v === 'string' && /^0x[0-9a-fA-F]{40}$/.test(v)

function argText(value: unknown): string {
  if (Array.isArray(value)) return `${value.length} ${value.length === 1 ? 'item' : 'items'}`
  const s = String(value)
  return s.length > 18 ? `${s.slice(0, 10)}…` : s
}
</script>

<template>
  <section v-if="line" class="details" aria-label="Story line">
    <header>
      <UBadge :label="kinds[line.kind].label" :color="kinds[line.kind].color" variant="subtle" size="sm" class="uppercase" />
      <span class="when">{{ when }}</span>
    </header>
    <p class="concept"><StorySentence :line="line" :deployment="deployment" /></p>

    <div v-if="entries.length" class="passbook">
      <PassbookEntry v-for="(m, i) in entries" :key="i" :entry="m" />
    </div>

    <template v-if="line.kind !== 'operator'">
      <dl class="facts">
        <dt>Through</dt>
        <dd>{{ line.channel }}</dd>
        <template v-if="line.signers?.length">
          <dt>Signed by</dt>
          <dd>{{ line.signers.join(', ') }}</dd>
        </template>
        <template v-if="line.role">
          <dt>Role checked</dt>
          <dd>{{ line.role }}</dd>
        </template>
        <template v-if="line.reason">
          <dt>Refused because</dt>
          <dd class="bad">{{ reasonOf(line) }}</dd>
        </template>
      </dl>

      <div v-if="places.length" class="block">
        <h3>Involved</h3>
        <span class="people">
          <UButton
            v-for="p in places"
            :key="p.id"
            :label="p.title"
            variant="outline"
            size="xs"
            class="rounded-full text-(--tone,var(--ui-text)) ring-(--tone,var(--ui-border-accented))"
            :class="p.tone && `tone-${p.tone}`"
            @click="emit('select', p.id)"
          />
        </span>
      </div>

      <div v-if="ledger.length" class="block">
        <h3>Ledger entry</h3>
        <dl class="figures">
          <template v-for="(l, i) in ledger" :key="i">
            <dt>{{ l.account }}</dt>
            <dd class="money">{{ l.amount }}</dd>
          </template>
        </dl>
        <UButton label="See the rows it moved on the balance sheet" variant="link" size="xs" class="px-0 underline" @click="emit('sheet')" />
      </div>

      <div class="block chain">
        <h3>On chain</h3>
        <p v-if="line.tx">Transaction <ExplorerLink :base="base" kind="tx" :value="line.tx" /></p>
        <p v-else>Refused before it was sent: the chain rejected it when it was simulated, so it left no transaction.</p>
        <p>{{ line.tx ? 'In block' : 'Simulated at block' }} <ExplorerLink :base="base" kind="block" :value="line.block" /></p>
        <p v-if="account">Acting from {{ name(account) }} <ExplorerLink :base="base" kind="address" :value="account" /></p>
        <p v-if="line.reason">Check that failed: {{ line.reason.error }}</p>
        <div v-for="(e, i) in line.events" :key="i" class="event">
          <div>
            <strong>{{ e.contract }}.{{ e.name }}</strong>
            · <ExplorerLink :base="base" kind="address" :value="e.address" />
          </div>
          <div v-for="(v, k) in e.args" :key="k" class="arg">
            {{ k }} =
            <template v-if="isAddress(v)">{{ name(v) }} <ExplorerLink :base="base" kind="address" :value="v" /></template>
            <span v-else :title="String(v)">{{ argText(v) }}</span>
          </div>
        </div>
        <p v-if="!base" class="note">Recorded on a local chain, so there is no block explorer to link to.</p>
      </div>
    </template>
    <p v-else class="note">A command from the control panel. It drives the run but is not a bank event, so nothing of it is on chain.</p>
  </section>
  <p v-else class="empty">This line is not in the run at this point.</p>
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

.bad {
  color: var(--ui-error);
}

.when {
  font-size: 12px;
  color: var(--ui-text-muted);
}

.concept {
  margin: 6px 0 10px;
  font-size: 15px;
  line-height: 1.45;
}

.figures {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 2px 12px;
  margin: 0 0 6px;
  padding: 8px 10px;
  background: var(--ui-bg-elevated);
  border-radius: 6px;
}

.passbook {
  margin: 0 0 10px;
  padding: 8px 10px;
  background: var(--ui-bg-elevated);
  border-radius: 6px;
}

.figures dd {
  text-align: right;
}

.facts {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 2px 12px;
  margin: 0 0 12px;
}

dt {
  color: var(--ui-text-muted);
}

dd {
  margin: 0;
}

.block {
  margin-bottom: 12px;
}

h3 {
  margin: 0 0 4px;
  font-size: 13px;
  font-weight: 600;
}

.people {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}

.chain {
  font: 12px/1.6 ui-monospace, monospace;
  overflow-wrap: anywhere;
}

.chain p {
  margin: 0 0 4px;
}

.event {
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px solid var(--ui-border);
}

.arg {
  padding-left: 12px;
  color: var(--ui-text-muted);
}

.note,
.empty {
  color: var(--ui-text-muted);
  font-size: 12px;
}
</style>
