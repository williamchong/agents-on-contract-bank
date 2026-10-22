<script setup lang="ts">
import { computed } from 'vue'
import type { Card } from '~/composables/useControl'

// The scene being played, in one plain sentence: what an adverse scenario attempts or the claim a tour beat
// makes, then pass or fail once it ends. The control it tests, what to point at and each check are a click
// away. See docs/architecture.md#dashboard.
const props = defineProps<{ card: Card | undefined }>()

const status: Record<Card['status'], { label: string; color: 'warning' | 'success' | 'error'; border: string }> = {
  running: { label: 'Playing', color: 'warning', border: 'border-l-warning' },
  passed: { label: 'Passed', color: 'success', border: 'border-l-success' },
  failed: { label: 'Failed', color: 'error', border: 'border-l-error' },
}
// Fixed, so the card's parts are not redrawn for each line played while it shows.
const cardUi = { body: 'p-2.5 sm:p-2.5' }
const toggleUi = { trailingIcon: 'group-data-[state=open]:rotate-180 transition-transform' }
const passed = computed(() => props.card?.checks.filter((c) => c.pass).length ?? 0)
</script>

<template>
  <UCard
    v-if="card"
    as="section"
    aria-label="Scenario card"
    class="shrink-0 border-l-4 text-[13px]"
    :class="status[card.status].border"
    :ui="cardUi"
  >
    <header class="flex items-baseline justify-between gap-2">
      <h2 class="text-[15px] font-semibold">{{ card.title }}</h2>
      <UBadge :label="status[card.status].label" :color="status[card.status].color" variant="subtle" />
    </header>
    <p class="mt-1 leading-snug">{{ card.summary ?? card.claim }}</p>
    <p v-if="card.error" class="mt-1 text-error">{{ card.error }}</p>
    <UCollapsible v-if="card.control || card.pointAt || card.checks.length || (card.summary && card.claim)" class="mt-1.5">
      <UButton
        :label="card.checks.length ? `${passed} of ${card.checks.length} checks passed` : 'What it tests'"
        trailing-icon="i-lucide-chevron-down"
        variant="link"
        size="xs"
        class="group px-0 text-muted"
        :ui="toggleUi"
      />
      <template #content>
        <div class="space-y-1 pt-1">
          <p v-if="card.control"><strong>Control tested:</strong> {{ card.control }}</p>
          <p v-if="card.summary && card.claim"><strong>Claim:</strong> {{ card.claim }}</p>
          <p v-if="card.pointAt"><strong>Look at:</strong> {{ card.pointAt }}</p>
          <ul class="space-y-0.5">
            <li v-for="c in card.checks" :key="c.name" class="flex gap-1" :class="c.pass ? 'text-success' : 'text-error'">
              <UIcon :name="c.pass ? 'i-lucide-check' : 'i-lucide-x'" class="mt-0.5 size-4 flex-none" />
              <span>{{ c.name }}<template v-if="!c.pass && c.detail">: {{ c.detail }}</template></span>
            </li>
          </ul>
        </div>
      </template>
    </UCollapsible>
  </UCard>
</template>
