<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { TabsItem } from '@nuxt/ui'
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
// The count alone, so the tabs are rebuilt only when it changes, not on every line.
const waitingCount = computed(() => items.value.length)
const tabs = computed((): TabsItem[] => [
  { value: 'story', label: 'Story' },
  {
    value: 'waiting',
    label: 'Waiting',
    badge: waitingCount.value ? { label: waitingCount.value, color: 'warning', variant: 'solid' } : undefined,
  },
  { value: 'balance sheet', label: 'Balance sheet' },
  { value: 'details', label: 'Details' },
])
</script>

<template>
  <div class="flex h-screen flex-col">
    <header class="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-default bg-default px-4 py-2">
      <h1 class="text-[15px] font-semibold whitespace-nowrap">Agents on Contract Bank</h1>
      <UButton v-if="intro" label="What is this?" variant="outline" size="sm" class="rounded-full" @click="showIntro" />
      <InvariantStrip :state="state" :explorer="base" @open="open({ kind: 'check', key: $event })" />
      <div v-if="$slots.bar" class="flex basis-full"><slot name="bar" /></div>
    </header>
    <UAlert v-if="error" :title="error" color="warning" variant="subtle" class="rounded-none" role="status" />
    <main
      class="grid min-h-0 flex-1 grid-cols-1 grid-rows-[55vh_auto] min-[900px]:grid-cols-[minmax(0,1fr)_420px] min-[900px]:grid-rows-1"
    >
      <div class="min-h-0">
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
      <aside
        class="flex flex-col gap-3.5 overflow-y-auto border-t border-default bg-default px-4 py-3 min-[900px]:border-t-0 min-[900px]:border-l"
      >
        <slot name="panel" />
        <ScenarioCard :card="card" />
        <UTabs
          v-model="tab"
          :items="tabs"
          :content="false"
          variant="link"
          size="sm"
          aria-label="Panels"
          class="sticky -top-3 z-10 bg-default"
        />
        <div class="min-h-0" role="tabpanel">
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
            <UButton
              v-if="trail.length > 1 || from"
              label="Back"
              icon="i-lucide-arrow-left"
              variant="link"
              size="xs"
              class="mb-2 px-0"
              @click="back"
            />
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
</style>
