<script setup lang="ts">
import type { Entry } from '~/lib/story'
import { toneClass } from '~/town/palette'

// One passbook entry: who paid whom, and how much, each side in the colour of what it does. See
// docs/architecture.md#story-lines.
defineProps<{ entry: Entry }>()
</script>

<template>
  <div class="entry">
    <span class="party" :class="toneClass(entry.fromTone)">{{ entry.from }}</span>
    <span class="arrow" aria-hidden="true">→</span>
    <span class="hidden">to</span>
    <span class="party" :class="toneClass(entry.toTone)">{{ entry.to }}</span>
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

.party.who::before {
  content: '';
  display: inline-block;
  width: 8px;
  height: 8px;
  margin-right: 6px;
  border-radius: 50%;
  background: var(--tone);
  vertical-align: 1px;
}

.arrow {
  color: var(--ui-text-muted);
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
