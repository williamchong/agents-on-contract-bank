<script setup lang="ts">
// Contracts with a link to their source and their address on the block explorer, or a note that the chain
// has none. See docs/architecture.md#dashboard.
defineProps<{ contracts: { key: string; name: string; url: string; address?: string }[]; base: string | undefined }>()
</script>

<template>
  <ul class="contracts">
    <li v-for="c in contracts" :key="c.key">
      <a :href="c.url" target="_blank" rel="noopener">{{ c.name }}</a>
      <template v-if="c.address"> · <ExplorerLink :base="base" kind="address" :value="c.address" /></template>
    </li>
  </ul>
  <p v-if="!base" class="note">Recorded on a local chain, so there is no block explorer to link to.</p>
</template>

<style scoped>
.contracts {
  margin: 0;
  padding: 0;
  list-style: none;
}

a {
  color: inherit;
}

.note {
  margin: 0;
  color: var(--muted);
  font-size: 12px;
}
</style>
