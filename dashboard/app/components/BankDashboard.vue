<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { BankState } from '~/composables/useBank'
import type { Card, Panel } from '~/composables/useControl'
import { accountsMoved, namer, waiting, type Deployment, type Line } from '~/lib/story'
import { useIntro } from '~/composables/useIntro'
import type { CheckKey } from '~/lib/checks'
import { explorer, type EntityId } from '~/town/entities'

// The dashboard in layers, so a newcomer sees the scene and an expert can dig. On top, the bar that drives
// the run and the invariant strip, whose checks open to say what they mean, and the block, linked to the
// block explorer. The bank map, with the latest story line as its caption, which opens it, then beside it
// the scenario card and tabs for the story, what is waiting, the balance sheet and the details of whatever
// was opened: a place or person on the map, a story line or a check. Details lead on to each other and to
// the block explorer, with a way back. While an adverse scenario is shown, the tab it concerns comes
// forward, unless details are open. See docs/architecture.md#dashboard.
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
type Detail = { kind: 'entity'; id: EntityId } | { kind: 'line'; seq: number } | { kind: 'check'; key: CheckKey }
const tab = ref<Tab>('story')
// The details opened one from another, the one shown last, and the tab the first was opened from.
const trail = ref<Detail[]>([])
const from = ref<Tab>()
const detail = computed(() => trail.value.at(-1))
const selected = computed(() => (detail.value?.kind === 'line' ? detail.value.seq : undefined))
const entity = computed(() => (detail.value?.kind === 'entity' ? detail.value.id : undefined))
// A reset opens a fresh bank, at new addresses, and starts the story again, so what was opened before it is
// gone. A reconnect to the same bank keeps it.
watch(
  () => props.deployment?.contracts.ledger,
  () => {
    trail.value = []
    from.value = undefined
  },
)
const moved = computed(() => {
  const line = props.lines.find((l) => l.seq === selected.value)
  return line ? accountsMoved(line) : []
})
const adverse = computed(() => (props.card?.kind === 'adverse' ? props.card : undefined))
watch(
  () => adverse.value?.title,
  () => {
    if (adverse.value?.panel && tab.value !== 'details') tab.value = adverse.value.panel
  },
)

// Back from the first detail returns to the tab it was opened from, so opening one from the map while
// details are shown keeps that tab. Opening the detail already shown again adds no step to go back through.
function open(d: Detail, further = false) {
  if (!further) trail.value = [d]
  else if (JSON.stringify(d) !== JSON.stringify(detail.value)) trail.value = [...trail.value, d]
  if (!further && tab.value !== 'details') from.value = tab.value
  tab.value = 'details'
}

function back() {
  if (trail.value.length > 1) trail.value = trail.value.slice(0, -1)
  else if (from.value) tab.value = from.value
}

const base = computed(() => explorer(props.deployment?.chainId))

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
      <InvariantStrip :state="state" :explorer="base" @open="open({ kind: 'check', key: $event })" />
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
          @select="open({ kind: 'entity', id: $event })"
        >
          <template #caption>
            <p
              v-if="latest"
              class="caption on-light"
              :class="latest.kind"
              aria-live="polite"
              title="Open this line"
              tabindex="0"
              @click="open({ kind: 'line', seq: latest.seq })"
              @keydown.enter="open({ kind: 'line', seq: latest.seq })"
            >
              <StorySentence :line="latest" :deployment="deployment" />
            </p>
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
            @select="open({ kind: 'line', seq: $event })"
          />
          <WaitingStrip v-else-if="tab === 'waiting'" :items="items" />
          <BalanceSheet v-else-if="tab === 'balance sheet'" :state="state" :lines="lines" :moved="moved" />
          <template v-else>
            <button v-if="trail.length > 1 || from" class="back" @click="back">← Back</button>
            <LineDetails
              v-if="detail?.kind === 'line'"
              :seq="detail.seq"
              :deployment="deployment"
              :lines="lines"
              @select="open({ kind: 'entity', id: $event }, true)"
              @sheet="tab = 'balance sheet'"
            />
            <CheckDetails
              v-else-if="detail?.kind === 'check'"
              :id="detail.key"
              :deployment="deployment"
              :state="state"
              @select="open({ kind: 'entity', id: $event }, true)"
            />
            <EntityDetails
              v-else
              :id="entity"
              :deployment="deployment"
              :state="state"
              :lines="lines"
              @select="open({ kind: 'entity', id: $event }, true)"
              @line="open({ kind: 'line', seq: $event }, true)"
            />
          </template>
        </div>
      </aside>
    </main>
    <IntroCard v-if="intro" :chain-id="deployment?.chainId" />
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

.back {
  font: inherit;
  font-size: 12px;
  margin-bottom: 8px;
  padding: 0;
  border: 0;
  background: none;
  color: var(--muted);
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
  cursor: pointer;
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
