<script setup lang="ts">
import { computed } from 'vue'
import { sentence, who, type Deployment, type Line } from '~/lib/story'
import { housedCustomers } from '~/town/focus'
import { actorTone, toneClass, type Tone } from '~/town/palette'

// A line's plain sentence with whoever acted, and every customer it names, in the colour of what they do, as
// the passbook does. `plain` leaves money unmarked where the passbook above already shows it. See
// docs/architecture.md#story-lines.
const props = defineProps<{ line: Line; deployment: Deployment | undefined; plain?: boolean }>()

const escape = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

const parts = computed((): { t: string; tone?: Tone }[] => {
  const text = sentence(props.line)
  const d = props.deployment
  if (!d || props.line.kind === 'operator') return [{ t: text }]
  const names = new Map<string, Tone>(housedCustomers(d).map((n) => [n, 'customer']))
  const tone = actorTone(d, props.line)
  if (tone) names.set(who(props.line.actor), tone)
  if (!names.size) return [{ t: text }]
  // Longest first, so a name is never matched by a shorter one inside it.
  const pattern = new RegExp(`\\b(${[...names.keys()].sort((a, b) => b.length - a.length).map(escape).join('|')})\\b`)
  return text.split(pattern).map((t, i) => ({ t, tone: i % 2 === 1 ? names.get(t) : undefined }))
})
</script>

<template>
  <template v-for="(p, i) in parts" :key="i"><span v-if="p.tone" :class="toneClass(p.tone)">{{ p.t }}</span><template v-else-if="plain">{{ p.t }}</template><MoneyText v-else :text="p.t" /></template>
</template>
