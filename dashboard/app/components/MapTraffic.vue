<script setup lang="ts">
import { useLoop } from '@tresjs/core'
import { Html } from '@tresjs/cientos'
import { ref, shallowRef, watch } from 'vue'
import { hkd, holder, movements, reasonOf, type Deployment, type Line } from '~/lib/story'
import { buildings, houseLots, type BuildingId, type Vec3 } from '~/town/layout'

// Money moving as coins between the places it was posted from and to, and a barrier where an attempt was
// refused; the rule that stopped it is in the map's caption and the story. Nothing moves that the chain did
// not report: each stack of coins is a transfer of the deposit token in a line's receipt. See
// docs/architecture.md#bank-map.
const props = defineProps<{ deployment: Deployment; lines: Line[] }>()

interface Van {
  id: number
  from: Vec3
  to: Vec3
  label: string
  start: number
}

interface Barrier {
  id: number
  at: Vec3
  // Its place in the stack of barriers standing at the same spot, so their reasons can all be read.
  level: number
  label: string
  until: number
}

const VAN_SECONDS = 2.2
const BARRIER_SECONDS = 7

const vans = shallowRef<Van[]>([])
const barriers = shallowRef<Barrier[]>([])
const now = ref(0)
let ids = 0
// Lines already on screen when the map opened are history, not traffic.
let seen = props.lines.length

const place = (id: BuildingId): Vec3 => {
  const b = buildings.find((x) => x.id === id) ?? buildings[0]!
  return [b.position[0], 0, b.position[2]]
}

function addressPlace(address: string, other: string, channel: string): Vec3 {
  const d = props.deployment
  const a = address.toLowerCase()
  const customers = Object.entries(d.customers).filter(([n]) => n !== 'other customers')
  const i = customers.findIndex(([, x]) => x.toLowerCase() === a)
  if (i >= 0) return houseLots[i] ?? place('head-office')
  if (a === d.customers['other customers']?.toLowerCase()) return [-12, 0, 9]
  switch (holder(d, address, other, channel)) {
    case 'Another bank':
      return place('clearing-house')
    case 'Cash':
    case 'ATM':
      return place(channel === 'atm' ? 'atm' : 'branch')
    case 'Branch':
      return place('branch')
    case 'Post office':
      return place('post-office')
  }
  return place('head-office')
}

function refusalPlace(line: Line): Vec3 {
  const byChannel: Record<string, BuildingId> = { atm: 'atm', branch: 'branch', partner: 'clearing-house', admin: 'town-hall' }
  if (byChannel[line.channel]) return place(byChannel[line.channel]!)
  const customers = Object.keys(props.deployment.customers)
  const i = customers.indexOf(line.actor)
  return i >= 0 && houseLots[i] ? houseLots[i]! : place('head-office')
}

watch(
  () => props.lines.length,
  (length) => {
    if (length < seen) seen = 0
    const t = now.value
    const fresh = props.lines.slice(seen)
    seen = length
    const newVans: Van[] = []
    fresh.forEach((line, n) => {
      for (const m of movements(line)) {
        const from = addressPlace(m.from, m.to, m.channel)
        const to = addressPlace(m.to, m.from, m.channel)
        if (from[0] === to[0] && from[2] === to[2]) continue
        newVans.push({ id: ++ids, from, to, label: hkd(m.amount), start: t + n * 0.4 })
      }
      if (line.kind === 'refused') {
        const at = refusalPlace(line)
        const level = barriers.value.filter((b) => b.at[0] === at[0] && b.at[2] === at[2]).length
        barriers.value = [...barriers.value, { id: ++ids, at, level, label: reasonOf(line), until: t + BARRIER_SECONDS }]
      }
    })
    if (newVans.length) vans.value = [...vans.value, ...newVans]
  },
)

const { onBeforeRender } = useLoop()
onBeforeRender(({ elapsed }) => {
  now.value = elapsed
  if (vans.value.some((v) => elapsed > v.start + VAN_SECONDS)) vans.value = vans.value.filter((v) => elapsed <= v.start + VAN_SECONDS)
  if (barriers.value.some((b) => elapsed > b.until)) barriers.value = barriers.value.filter((b) => elapsed <= b.until)
})

// Where a van is along its trip: a short hop so it clears the buildings it passes.
function vanAt(v: Van): Vec3 {
  const p = Math.min(1, Math.max(0, (now.value - v.start) / VAN_SECONDS))
  const lerp = (a: number, b: number) => a + (b - a) * p
  return [lerp(v.from[0], v.to[0]), 0.4 + Math.sin(p * Math.PI) * 2.2, lerp(v.from[2], v.to[2])]
}
</script>

<template>
  <TresGroup v-for="v in vans" :key="v.id" :position="vanAt(v)" :visible="now >= v.start">
    <!-- Money is a spinning stack of coins, not a box, so it cannot be taken for a building. -->
    <TresGroup :rotation-z="0.5" :rotation-y="now * 3">
      <TresMesh v-for="k in 3" :key="k" :position-y="(k - 2) * 0.14" :cast-shadow="k === 2">
        <TresCylinderGeometry :args="[0.45, 0.45, 0.12, 24]" />
        <TresMeshStandardMaterial color="#f2b134" :metalness="0.6" :roughness="0.3" />
      </TresMesh>
    </TresGroup>
    <Html :position="[0, 0.7, 0]" center :z-index-range="[5, 0]">
      <span class="van">{{ v.label }}</span>
    </Html>
  </TresGroup>

  <TresGroup v-for="b in barriers" :key="b.id" :position="b.at">
    <TresMesh :position="[0, 0.6, 1.6]">
      <TresBoxGeometry :args="[2.4, 0.18, 0.18]" />
      <TresMeshStandardMaterial color="#c0392b" />
    </TresMesh>
    <Html :position="[0, 1.2 + b.level * 0.5, 1.6]" center :z-index-range="[5, 0]">
      <span class="barrier" :title="b.label">✗ Refused</span>
    </Html>
  </TresGroup>
</template>

<style scoped>
.van,
.barrier {
  font: 600 11px/1.2 system-ui, sans-serif;
  padding: 2px 6px;
  border-radius: 4px;
  white-space: nowrap;
  pointer-events: none;
}

.van {
  background: #fff3d6;
  color: #5a3b00;
}

.barrier {
  background: #c0392b;
  color: #fff;
  white-space: nowrap;
}
</style>
