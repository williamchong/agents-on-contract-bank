<script setup lang="ts">
import { computed } from 'vue'

// A transaction, block or address, linked to its page on the block explorer, or shown shortened with the
// whole value on hover where the chain has none. See docs/architecture.md#dashboard.
const props = defineProps<{ base: string | undefined; kind: 'tx' | 'block' | 'address'; value: string; label?: string }>()

const text = computed(() => props.label ?? (props.kind === 'block' ? props.value : `${props.value.slice(0, 10)}…`))
</script>

<template>
  <a v-if="base" class="explorer" :href="`${base}/${kind}/${value}`" target="_blank" rel="noopener" :title="value" @click.stop>{{ text }} ↗</a>
  <span v-else :title="value">{{ text }}</span>
</template>

<style scoped>
.explorer {
  color: inherit;
}
</style>
