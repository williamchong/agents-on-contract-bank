<script setup lang="ts">
import { useTres } from '@tresjs/core'
import { computed } from 'vue'
import type { Vec3 } from '~/town/layout'

// Tres keeps a perspective camera's aspect in step with the canvas but leaves an orthographic camera's frustum
// at three's default, so the frustum is set here from the canvas size. The view height is in world units.
// The frustum is bound as plain props, as a change of args would rebuild the camera and lose its parent.
// On a narrow canvas, such as a phone held upright, the view grows so it is still `minViewWidth` across.
const props = defineProps<{
  position: Vec3
  target: Vec3
  viewHeight: number
  minViewWidth?: number
}>()

const { sizes } = useTres()

const halfHeight = computed(() => Math.max(props.viewHeight, (props.minViewWidth ?? 0) / (sizes.aspectRatio.value || 1)) / 2)
const halfWidth = computed(() => halfHeight.value * (sizes.aspectRatio.value || 1))
</script>

<template>
  <TresOrthographicCamera
    :left="-halfWidth"
    :right="halfWidth"
    :top="halfHeight"
    :bottom="-halfHeight"
    :near="0.1"
    :far="200"
    :position="position"
    :look-at="target"
  />
</template>
