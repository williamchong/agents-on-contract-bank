<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { BankState } from '~/composables/useBank'
import type { Card, Panel } from '~/composables/useControl'
import { accountsMoved, namer, sentence, waiting, type Deployment, type Line } from '~/lib/story'
import { useIntro } from '~/composables/useIntro'
import type { EntityId } from '~/town/entities'

// The dashboard in layers, so a newcomer sees the scene and an expert can dig. On top, the bar that drives
// the run, the invariant strip and the under the hood switch, which adds the technical detail everywhere.
// The bank map, with the latest story line as its caption, then beside it the scenario card and tabs for
// the story, what is waiting, the balance sheet and the details of whatever is selected on the map. While
// an adverse scenario is shown, the tab it concerns comes forward. See docs/architecture.md#dashboard.
const props = defineProps<{
  deployment: Deployment | undefined
  lines: Line[]
  card: Card | undefined
  state: BankState | undefined
  error: string | undefined
  // Moves on when playback jumps, so the bank map takes the lines jumped over as history.
  epoch?: number
  // Whether to offer the "What is this?" introduction, for visitors to the public replay.
  intro?: boolean
}>()

const { show: showIntro } = useIntro()

type Tab = Panel | 'details'
const tab = ref<Tab>('story')
const underTheHood = ref(false)
const selected = ref<number>()
const entity = ref<EntityId>()
// A reset starts the story again, so a line selected before it is gone.
watch(
  () => props.deployment,
  () => (selected.value = undefined),
)
const moved = computed(() => {
  const line = props.lines.find((l) => l.seq === selected.value)
  return line ? accountsMoved(line) : []
})
const adverse = computed(() => (props.card?.kind === 'adverse' ? props.card : undefined))
watch(
  () => adverse.value?.title,
  () => {
    if (adverse.value?.panel) tab.value = adverse.value.panel
  },
)

function pick(id: EntityId) {
  entity.value = id
  tab.value = 'details'
}

const items = computed(() => (props.deployment ? waiting(props.lines, namer(props.deployment)) : []))
const latest = computed(() => props.lines.findLast((l) => l.kind !== 'operator'))
const tabs = computed((): { id: Tab; label: string; count?: number }[] => [
  { id: 'story', label: 'Story' },
  { id: 'waiting', label: 'Waiting', count: items.value.length },
  { id: 'balance sheet', label: 'Balance sheet' },
  { id: 'details', label: 'Details' },
])
</script>

<template>
  <div class="dashboard">
    <header class="top">
      <h1>Agents on Contract Bank</h1>
      <button v-if="intro" class="about" @click="showIntro">What is this?</button>
      <InvariantStrip :state="state" :under-the-hood="underTheHood" />
      <label class="hood-switch" title="Show signers, roles checked, chain events, transactions and contracts">
        <input v-model="underTheHood" type="checkbox" /> Under the hood
      </label>
      <div v-if="$slots.bar" class="transport"><slot name="bar" /></div>
    </header>
    <p v-if="error" class="notice" role="status">{{ error }}</p>
    <main>
      <div class="map">
        <BankMap
          :deployment="deployment"
          :state="state"
          :lines="lines"
          :focus="card?.building"
          :scenario="card"
          :epoch="epoch"
          :selected="entity"
          @select="pick"
        >
          <template #caption>
            <p v-if="latest" class="caption" :class="latest.kind" aria-live="polite"><MoneyText :text="sentence(latest)" /></p>
          </template>
        </BankMap>
      </div>
      <aside>
        <slot name="panel" />
        <ScenarioCard :card="card" />
        <div class="tabs" role="tablist" aria-label="Panels">
          <button
            v-for="t in tabs"
            :key="t.id"
            role="tab"
            :aria-selected="tab === t.id"
            :class="{ on: tab === t.id }"
            @click="tab = t.id"
          >
            {{ t.label }}<span v-if="t.count" class="count">{{ t.count }}</span>
          </button>
        </div>
        <div class="panel" role="tabpanel">
          <StoryView
            v-if="tab === 'story'"
            :lines="lines"
            :deployment="deployment"
            :selected="selected"
            :alarms="adverse"
            :under-the-hood="underTheHood"
            @select="selected = $event"
          />
          <WaitingStrip v-else-if="tab === 'waiting'" :items="items" />
          <BalanceSheet v-else-if="tab === 'balance sheet'" :state="state" :lines="lines" :moved="moved" />
          <EntityDetails
            v-else
            :id="entity"
            :deployment="deployment"
            :state="state"
            :lines="lines"
            :under-the-hood="underTheHood"
            @select="pick"
          />
        </div>
      </aside>
    </main>
    <IntroCard v-if="intro" />
  </div>
</template>

<style scoped>
.top {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px 16px;
  padding: 8px 16px;
  background: var(--panel);
  border-bottom: 1px solid var(--line);
}

h1 {
  margin: 0;
  font-size: 15px;
  white-space: nowrap;
}

.transport {
  display: flex;
  flex-basis: 100%;
}

.about {
  font: inherit;
  font-size: 13px;
  padding: 3px 10px;
  border-radius: 999px;
  border: 1px solid var(--line);
  background: none;
  color: var(--ink);
  cursor: pointer;
}

.hood-switch {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 13px;
  white-space: nowrap;
  cursor: pointer;
}

.caption {
  margin: 0;
  max-width: 560px;
  padding: 8px 12px;
  border-radius: 8px;
  background: rgb(255 255 255 / 92%);
  color: #1f2a33;
  font-size: 14px;
  line-height: 1.4;
  box-shadow: 0 1px 4px rgb(0 0 0 / 12%);
}

.caption.refused {
  color: #b3261e;
}

.tabs {
  display: flex;
  gap: 2px;
  border-bottom: 1px solid var(--line);
  position: sticky;
  top: -12px;
  background: var(--panel);
  z-index: 1;
}

.tabs button {
  font: inherit;
  font-size: 13px;
  padding: 7px 10px;
  border: 0;
  border-bottom: 2px solid transparent;
  background: none;
  color: var(--muted);
  cursor: pointer;
}

.tabs button.on {
  color: var(--ink);
  border-bottom-color: var(--ink);
  font-weight: 600;
}

.count {
  margin-left: 5px;
  padding: 0 6px;
  border-radius: 999px;
  background: var(--wait);
  color: #fff;
  font-size: 11px;
}

.panel {
  min-height: 0;
}
</style>
