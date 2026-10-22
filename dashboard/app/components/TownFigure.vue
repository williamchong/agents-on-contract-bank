<script setup lang="ts">
// A person on the bank map: a body and a head, so people cannot be taken for the boxes that are buildings.
// See docs/architecture.md#bank-map.
defineProps<{ color: string }>()
const emit = defineEmits<{ click: [e: { stopPropagation?: () => void }]; pointerenter: []; pointerleave: [] }>()
const on = {
  click: (e: { stopPropagation?: () => void }) => emit('click', e),
  pointerenter: () => emit('pointerenter'),
  pointerleave: () => emit('pointerleave'),
}
</script>

<template>
  <TresGroup>
    <TresMesh :position-y="0.38" cast-shadow v-on="on">
      <TresCapsuleGeometry :args="[0.18, 0.4, 4, 8]" />
      <TresMeshStandardMaterial :color="color" />
    </TresMesh>
    <TresMesh :position-y="0.86" cast-shadow v-on="on">
      <TresSphereGeometry :args="[0.16, 12, 8]" />
      <TresMeshStandardMaterial :color="color" />
    </TresMesh>
  </TresGroup>
</template>
