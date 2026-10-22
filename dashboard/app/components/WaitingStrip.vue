<script setup lang="ts">
import type { Waiting } from '~/lib/story'

// Everything started and not yet finished, with who or what it waits for. An item leaves the strip when
// its story line completes, refuses or reverses it. See docs/architecture.md#dashboard.
defineProps<{ items: Waiting[] }>()
</script>

<template>
  <section aria-label="Waiting strip" class="text-[13px]">
    <p v-if="!items.length" class="text-muted">Nothing is waiting.</p>
    <ul class="space-y-1">
      <li v-for="item in items" :key="item.key" class="border-l-3 border-warning bg-elevated px-2 py-1.5"><MoneyText :text="item.what" /></li>
    </ul>
  </section>
</template>
