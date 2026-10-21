<script setup lang="ts">
import { computed } from 'vue'

// Text with every amount of money in it set apart, so money reads differently from the words around it.
const props = defineProps<{ text: string }>()

const AMOUNT = /(−?-?HK\$[\d,]+(?:\.\d+)?)/
const parts = computed(() => props.text.split(AMOUNT).map((t, i) => ({ t, money: i % 2 === 1 })))
</script>

<template>
  <template v-for="(p, i) in parts" :key="i"><span v-if="p.money" class="money">{{ p.t }}</span><template v-else>{{ p.t }}</template></template>
</template>
