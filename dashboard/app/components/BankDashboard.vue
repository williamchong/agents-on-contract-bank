<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { BankState } from '~/composables/useBank'
import type { Card, Panel } from '~/composables/useControl'
import { accountsMoved, type Deployment, type Line } from '~/lib/story'

// The dashboard's panels: the invariant strip across the top, the bank map, the story view with its
// waiting strip, the scenario card and the balance sheet, with the control or playback panel above them.
// While an adverse scenario is shown, the panel it concerns comes forward, just under its card. See
// docs/architecture.md#dashboard.
const props = defineProps<{
  deployment: Deployment | undefined
  lines: Line[]
  card: Card | undefined
  state: BankState | undefined
  error: string | undefined
  // Moves on when playback jumps, so the bank map takes the lines jumped over as history.
  epoch?: number
}>()

const selected = ref<number>()
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
const order = (panel: Panel) => ({ order: adverse.value?.panel === panel ? 2 : 3 })
</script>

<template>
  <div class="dashboard">
    <InvariantStrip :state="state" />
    <p v-if="error" class="notice" role="status">{{ error }}</p>
    <main>
      <div class="map">
        <BankMap :deployment="deployment" :state="state" :lines="lines" :focus="card?.building" :epoch="epoch" />
      </div>
      <aside>
        <slot name="panel" />
        <ScenarioCard :card="card" :style="{ order: 1 }" />
        <WaitingStrip :lines="lines" :deployment="deployment" :style="order('waiting')" />
        <StoryView
          :lines="lines"
          :deployment="deployment"
          :selected="selected"
          :alarms="adverse"
          :style="order('story')"
          @select="selected = $event"
        />
        <BalanceSheet :state="state" :lines="lines" :moved="moved" :style="order('balance sheet')" />
      </aside>
    </main>
  </div>
</template>
