<script setup lang="ts">
import { useLoop, useTres } from '@tresjs/core'
import { computed, ref } from 'vue'
import { Vector3 } from 'three'
import type { Vec3 } from '~/town/layout'

// Tres keeps a perspective camera's aspect in step with the canvas but leaves an orthographic camera's frustum
// at three's default, so the frustum is set here from the canvas size. The view height is in world units.
// The frustum is bound as plain props, as a change of args would rebuild the camera and lose its parent.
// On a narrow canvas, such as a phone held upright, the view grows so it is still `minViewWidth` across.
// Given points to `frame`, the camera glides along its view to fit them, never closer than `minFrameHeight`
// nor wider than the whole view, and glides back when they are gone.
const props = defineProps<{
  position: Vec3
  target: Vec3
  viewHeight: number
  minViewWidth?: number
  frame?: Vec3[]
  minFrameHeight?: number
}>()

const { sizes } = useTres()
const aspect = computed(() => sizes.aspectRatio.value || 1)
const fullHeight = computed(() => Math.max(props.viewHeight, (props.minViewWidth ?? 0) / aspect.value))

// The screen's axes in the world: the camera only slides along them, so its angle never changes.
const offset = computed(() => new Vector3(...props.position).sub(new Vector3(...props.target)))
const axes = computed(() => {
  const back = offset.value.clone().normalize()
  const right = new Vector3(0, 1, 0).cross(back).normalize()
  return { right, up: back.clone().cross(right) }
})

// Where the view should be: how far it slides from the target along each screen axis, and its height.
const goal = computed(() => {
  const points = props.frame ?? []
  if (!points.length) return { x: 0, y: 0, height: fullHeight.value }
  const { right, up } = axes.value
  const origin = new Vector3(...props.target)
  const xs: number[] = []
  const ys: number[] = []
  for (const p of points) {
    const v = new Vector3(...p).sub(origin)
    xs.push(v.dot(right))
    ys.push(v.dot(up))
  }
  const [x0, x1, y0, y1] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)]
  const margin = 1.25
  const height = Math.min(fullHeight.value, Math.max(props.minFrameHeight ?? 0, (y1 - y0) * margin, ((x1 - x0) * margin) / aspect.value))
  return { x: (x0 + x1) / 2, y: (y0 + y1) / 2, height }
})

const view = ref({ x: 0, y: 0, height: fullHeight.value })
// The camera glides only to and from a frame; the canvas sizing itself, on load or a resize, applies at once.
let gliding = false
const { onBeforeRender } = useLoop()
onBeforeRender(({ delta }) => {
  const g = goal.value
  const v = view.value
  const framing = !!props.frame?.length
  const off = Math.abs(g.x - v.x) + Math.abs(g.y - v.y) + Math.abs(g.height - v.height)
  if (off < 0.02 || (!gliding && !framing)) {
    if (off) view.value = g
    gliding = framing
    return
  }
  gliding = true
  // About a second to arrive, slowing as it does.
  const k = 1 - Math.exp(-delta * 3)
  view.value = { x: v.x + (g.x - v.x) * k, y: v.y + (g.y - v.y) * k, height: v.height + (g.height - v.height) * k }
})

const shift = computed(() => {
  const { right, up } = axes.value
  return right.clone().multiplyScalar(view.value.x).add(up.clone().multiplyScalar(view.value.y))
})
const at = computed((): Vec3 => new Vector3(...props.target).add(shift.value).toArray())
const from = computed((): Vec3 => new Vector3(...props.target).add(shift.value).add(offset.value).toArray())
const halfHeight = computed(() => view.value.height / 2)
const halfWidth = computed(() => halfHeight.value * aspect.value)
</script>

<template>
  <TresOrthographicCamera
    :left="-halfWidth"
    :right="halfWidth"
    :top="halfHeight"
    :bottom="-halfHeight"
    :near="0.1"
    :far="200"
    :position="from"
    :look-at="at"
  />
</template>
