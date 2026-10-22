<script setup lang="ts">
import { computed } from 'vue'

// A transaction, block or address, linked to its page on the block explorer, or shown shortened with the
// whole value on hover where the chain has none. See docs/architecture.md#dashboard.
const props = defineProps<{ base: string | undefined; kind: 'tx' | 'block' | 'address'; value: string; label?: string }>()

const text = computed(() => props.label ?? (props.kind === 'block' ? props.value : `${props.value.slice(0, 10)}…`))
</script>

<template>
  <ULink v-if="base" raw :to="`${base}/${kind}/${value}`" target="_blank" class="underline" :title="value" @click.stop>
    {{ text }}<UIcon name="i-lucide-arrow-up-right" class="size-3 align-[-1px]" />
  </ULink>
  <span v-else :title="value">{{ text }}</span>
</template>
