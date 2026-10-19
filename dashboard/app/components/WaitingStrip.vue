<script setup lang="ts">
import { computed } from 'vue'
import { namer, waiting, type Deployment, type Line } from '~/lib/story'

// Everything started and not yet finished, with who or what it waits for. An item leaves the strip when
// its story line completes, refuses or reverses it. See docs/architecture.md#dashboard.
const props = defineProps<{ lines: Line[]; deployment: Deployment | undefined }>()

const items = computed(() => (props.deployment ? waiting(props.lines, namer(props.deployment)) : []))
</script>

<template>
  <section aria-label="Waiting strip">
    <h2>Waiting</h2>
    <p v-if="!items.length" class="empty">Nothing is waiting.</p>
    <ul>
      <li v-for="item in items" :key="item.key">{{ item.what }}</li>
    </ul>
  </section>
</template>

<style scoped>
h2 {
  margin: 0 0 6px;
  font-size: 15px;
}

ul {
  margin: 0;
  padding: 0;
  list-style: none;
}

li {
  padding: 5px 8px;
  margin-bottom: 4px;
  border-left: 3px solid var(--wait);
  background: var(--chip);
  font-size: 13px;
}

.empty {
  color: var(--muted);
  font-size: 13px;
  margin: 0;
}
</style>
