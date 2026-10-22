<script setup lang="ts">
import type { Entry } from '~/lib/story'

// One passbook entry: who paid whom, and how much. See docs/architecture.md#story-lines.
defineProps<{ entry: Entry }>()
</script>

<template>
  <div class="entry">
    <span class="party">{{ entry.from }}</span>
    <span class="arrow" aria-hidden="true">→</span>
    <span class="hidden">to</span>
    <span class="party">{{ entry.to }}</span>
    <span class="money">{{ entry.amount }}</span>
  </div>
</template>

<style scoped>
.entry {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr) auto;
  gap: 8px;
  align-items: baseline;
  font-variant-numeric: tabular-nums;
}

.party {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.arrow {
  color: var(--muted);
}

.money {
  text-align: right;
  font-weight: 600;
}

.hidden {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip-path: inset(50%);
}
</style>
