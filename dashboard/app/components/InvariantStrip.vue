<script setup lang="ts">
import { computed } from 'vue'
import type { BankState } from '~/composables/useBank'
import { checks as checksOf, type CheckKey } from '~/lib/checks'

// The design's headline claims as of the latest block, each in a few words with the full claim on hover and
// what it means one click away, and the block, linked to the block explorer. See docs/architecture.md#dashboard.
const props = defineProps<{ state: BankState | undefined; explorer: string | undefined }>()
const emit = defineEmits<{ open: [key: CheckKey] }>()

const checks = computed(() => checksOf(props.state))

// A check that holds, fails, or cannot be told yet.
const looks = {
  ok: { icon: 'i-lucide-check', color: 'neutral', ui: { leadingIcon: 'text-success' } },
  broken: { icon: 'i-lucide-x', color: 'error', ui: {} },
  unknown: { icon: 'i-lucide-minus', color: 'neutral', ui: { leadingIcon: 'text-muted' } },
} as const

function look(ok: boolean | undefined) {
  if (ok === undefined) return looks.unknown
  return ok ? looks.ok : looks.broken
}
</script>

<template>
  <ul class="flex basis-full flex-nowrap gap-1.5 overflow-x-auto sm:basis-auto sm:flex-wrap" aria-label="Invariants">
    <li v-for="c in checks" :key="c.key" class="whitespace-nowrap">
      <UTooltip :text="c.full">
        <UButton
          :label="c.label"
          :icon="look(c.ok).icon"
          :color="look(c.ok).color"
          variant="soft"
          size="xs"
          class="rounded-full"
          :ui="look(c.ok).ui"
          @click="emit('open', c.key)"
        />
      </UTooltip>
    </li>
    <li v-if="state" class="px-1 text-xs whitespace-nowrap text-muted tabular-nums">
      <ExplorerLink :base="explorer" kind="block" :value="String(state.block)" :label="`Block ${state.block}`" />
    </li>
  </ul>
</template>
