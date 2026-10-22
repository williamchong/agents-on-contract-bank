<script setup lang="ts">
import { useLoop } from '@tresjs/core'
import { Html } from '@tresjs/cientos'
import { ref, shallowRef, watch } from 'vue'
import { attempted, hkd, movements, reasonOf, who, type Deployment, type Line, type Movement } from '~/lib/story'
import { parse, type EntityId } from '~/town/entities'
import { actorEntity, addressEntity, housedCustomers, involved, refusalEntity } from '~/town/focus'
import { buildings, houseLots, redTeamSpot, staffPosts, type BuildingId, type Vec3 } from '~/town/layout'
import { actorTone, tones } from '~/town/palette'

// Money moving as coins between the places it was posted from and to, and a request that moves none as a
// letter from whoever sent it. A refused attempt sets off as the real one would, until a wall rises in its
// way and sends it back; the rule that stopped it is on the wall. Nothing moves that the chain or the submission
// service did not report: each stack of coins is a transfer of the deposit token in a line's receipt, or the
// transfer a refused request would have made. See docs/architecture.md#bank-map.
const props = defineProps<{ deployment: Deployment; lines: Line[] }>()

interface Trip {
  id: number
  from: Vec3
  to: Vec3
  label: string
  start: number
  token: 'coins' | 'letter'
  // A refused trip turns back at the wall.
  refused: boolean
  // The colour of whoever set it off, on its label.
  color?: string
}

interface Wall {
  id: number
  at: Vec3
  // Its place in the stack of walls standing at the same spot, so their reasons can all be read.
  level: number
  label: string
  rise: number
  until: number
}

const TRIP_SECONDS = 2.2
// How far along its trip a refused attempt gets before the wall stops it, then how long it shakes there and
// takes to roll back.
const HIT = 0.45
// The wall stands just beyond where the attempt stops, so it is seen to strike it, not pass into it.
const WALL_AT = HIT + 0.04
const SHAKE_SECONDS = 0.35
const BACK_SECONDS = 0.9
const REFUSED_SECONDS = HIT * TRIP_SECONDS + SHAKE_SECONDS + BACK_SECONDS
// The wall rises from 30% of the trip, so it is plainly in the way before the attempt reaches it.
const RISE_AT = 0.3 * TRIP_SECONDS
const RISE_SECONDS = 0.25
const WALL_SECONDS = 7
const WALL_HEIGHT = 3.4
const WALL_WIDTH = 2.4
// Walls face the isometric camera, so one is never seen edge on, whichever way the attempt runs.
const FACING_CAMERA = Math.PI / 4

// With reduced motion, trips glide flat without spinning or shaking, and walls stand without rising.
const still = typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

const trips = shallowRef<Trip[]>([])
const walls = shallowRef<Wall[]>([])
const now = ref(0)
let ids = 0
// Lines already on screen when the map opened are history, not traffic.
let seen = props.lines.length

const place = (id: BuildingId): Vec3 => {
  const b = buildings.find((x) => x.id === id) ?? buildings[0]!
  return [b.position[0], 0, b.position[2]]
}

// Where an entity stands: a customer at their house, staff at their building, the red team on the edge of
// town and the rest of the world's customers off the edge of the map.
function placeOf(id: EntityId | undefined): Vec3 {
  if (!id) return [-12, 0, 9]
  const p = parse(id)
  if (p.kind === 'customer') return houseLots[housedCustomers(props.deployment).indexOf(p.name)] ?? place('head-office')
  if (p.kind === 'staff') {
    if (p.name === 'red team') return redTeamSpot
    return place(staffPosts.find((x) => x.name === p.name)?.building ?? 'head-office')
  }
  return place(p.id)
}

const addressPlace = (address: string, other: string, channel: string) => placeOf(addressEntity(props.deployment, address, other, channel))

const same = (a: Vec3, b: Vec3) => Math.abs(a[0] - b[0]) < 0.1 && Math.abs(a[2] - b[2]) < 0.1

type Route = Pick<Trip, 'from' | 'to' | 'label' | 'token' | 'color'>

const toneColor = (line: Line) => {
  const t = actorTone(props.deployment, line)
  return t && tones[t].color
}

// Coins for a movement, labelled with who set it off.
function coins(line: Line, m: Movement): Route {
  return { from: addressPlace(m.from, m.to, m.channel), to: addressPlace(m.to, m.from, m.channel), label: `${who(line.actor)} · ${hkd(m.amount)}`, token: 'coins', color: toneColor(line) }
}

// A letter for a request that moves no money, labelled with who sent it and what it asks.
function letter(line: Line, from: Vec3, to: Vec3): Route {
  return { from, to, label: `${who(line.actor)} · ${line.action}`, token: 'letter', color: toneColor(line) }
}

// A refused line's trip: the money it would have moved, or else a letter from whoever acted to where they
// were refused. One that starts where it is refused comes up to the door from in front.
function attemptTrip(line: Line): Route {
  const m = attempted(line)
  const d = props.deployment
  const route = m ? coins(line, m) : letter(line, placeOf(actorEntity(d, line)), placeOf(refusalEntity(d, line)))
  if (same(route.from, route.to)) route.from = [route.to[0] + 2.6, 0, route.to[2] + 2.6]
  return route
}

// An allowed request that moves no money, such as an approval, a count or a role granted, goes as a letter
// from whoever acted to the first other place it involves. One that involves nowhere else stays put.
function letterTrip(line: Line): Route | undefined {
  const d = props.deployment
  const actor = actorEntity(d, line)
  if (!actor) return undefined
  const from = placeOf(actor)
  for (const id of involved(d, line)) {
    const to = placeOf(id)
    if (!same(from, to)) return letter(line, from, to)
  }
  return undefined
}

// Where a trip is at `p` of the way: a short hop so it clears the buildings it passes.
function along(t: Pick<Trip, 'from' | 'to'>, p: number): Vec3 {
  const lerp = (a: number, b: number) => a + (b - a) * p
  return [lerp(t.from[0], t.to[0]), still ? 0.6 : 0.4 + Math.sin(p * Math.PI) * 2.2, lerp(t.from[2], t.to[2])]
}

watch(
  () => props.lines.length,
  (length) => {
    if (length < seen) seen = 0
    const t = now.value
    const fresh = props.lines.slice(seen)
    seen = length
    const newTrips: Trip[] = []
    const newWalls: Wall[] = []
    fresh.forEach((line, n) => {
      const start = t + n * 0.4
      const moved = movements(line)
      for (const m of moved) {
        const route = coins(line, m)
        if (!same(route.from, route.to)) newTrips.push({ id: ++ids, ...route, start, refused: false })
      }
      const sent = line.kind === 'allowed' && !moved.length && letterTrip(line)
      if (sent) newTrips.push({ id: ++ids, ...sent, start, refused: false })
      if (line.kind === 'refused') {
        const trip: Trip = { id: ++ids, ...attemptTrip(line), start, refused: true }
        newTrips.push(trip)
        const [x, , z] = along(trip, WALL_AT)
        const at: Vec3 = [x, 0, z]
        const level = [...walls.value, ...newWalls].filter((w) => Math.hypot(w.at[0] - x, w.at[2] - z) < 1).length
        newWalls.push({ id: ++ids, at, level, label: reasonOf(line), rise: start + RISE_AT, until: start + WALL_SECONDS })
      }
    })
    if (newTrips.length) trips.value = [...trips.value, ...newTrips]
    if (newWalls.length) walls.value = [...walls.value, ...newWalls]
  },
)

const tripSeconds = (trip: Trip) => (trip.refused ? REFUSED_SECONDS : TRIP_SECONDS)

const { onBeforeRender } = useLoop()
onBeforeRender(({ elapsed }) => {
  now.value = elapsed
  if (trips.value.some((v) => elapsed > v.start + tripSeconds(v))) trips.value = trips.value.filter((v) => elapsed <= v.start + tripSeconds(v))
  if (walls.value.some((w) => elapsed > w.until)) walls.value = walls.value.filter((w) => elapsed <= w.until)
})

// How far along its trip it is: a refused one stops at the wall, shakes against it and rolls back.
function progress(trip: Trip): number {
  const e = now.value - trip.start
  if (!trip.refused) return Math.min(1, Math.max(0, e / TRIP_SECONDS))
  const reach = HIT * TRIP_SECONDS
  if (e < reach) return Math.max(0, e / TRIP_SECONDS)
  // The shake dies away, so the roll back starts from where it stopped.
  if (e < reach + SHAKE_SECONDS) return still ? HIT : HIT - 0.015 * (1 - (e - reach) / SHAKE_SECONDS) * Math.abs(Math.sin((e - reach) * 30))
  // Easing out, so it leaves the wall quickly and settles back where it set off.
  const back = Math.min(1, (e - reach - SHAKE_SECONDS) / BACK_SECONDS)
  return HIT * (1 - back) ** 2
}

// Once it has struck the wall an attempt turns red, so the one the wall stopped stands out from the traffic.
const struck = (trip: Trip) => trip.refused && now.value - trip.start >= HIT * TRIP_SECONDS

// How far a wall has risen: up as the attempt approaches, and down again as it goes.
function height(w: Wall): number {
  if (still) return 1
  const up = (now.value - w.rise) / RISE_SECONDS
  const down = (w.until - now.value) / RISE_SECONDS
  return Math.max(0.001, Math.min(1, up, down))
}
</script>

<template>
  <TresGroup v-for="v in trips" :key="v.id" :position="along(v, progress(v))" :visible="now >= v.start">
    <!-- Money is a spinning stack of coins and a request a letter, not a box, so neither is taken for a building. -->
    <TresGroup v-if="v.token === 'coins'" :rotation-z="0.5" :rotation-y="still ? 0 : now * 3">
      <TresMesh v-for="k in 3" :key="k" :position-y="(k - 2) * 0.14" :cast-shadow="k === 2">
        <TresCylinderGeometry :args="[0.45, 0.45, 0.12, 24]" />
        <TresMeshStandardMaterial :color="struck(v) ? '#c0392b' : '#f2b134'" :metalness="0.6" :roughness="0.3" />
      </TresMesh>
    </TresGroup>
    <TresMesh v-else :rotation-z="0.4" :rotation-y="still ? 0 : now * 2" cast-shadow>
      <TresBoxGeometry :args="[0.7, 0.05, 0.5]" />
      <TresMeshStandardMaterial :color="struck(v) ? '#c0392b' : '#fbf7ee'" />
    </TresMesh>
    <Html :position="[0, 0.7, 0]" center :z-index-range="[5, 0]">
      <span class="trip" :class="{ struck: struck(v) }" :style="v.color && { borderLeftColor: v.color }">{{ v.label }}</span>
    </Html>
  </TresGroup>

  <TresGroup v-for="w in walls" :key="w.id" :position="w.at" :visible="now >= w.rise">
    <TresMesh :rotation-y="FACING_CAMERA" :scale-y="height(w)" :position-y="(WALL_HEIGHT * height(w)) / 2">
      <TresBoxGeometry :args="[WALL_WIDTH, WALL_HEIGHT, 0.12]" />
      <TresMeshStandardMaterial color="#c0392b" transparent :opacity="0.55" />
    </TresMesh>
    <Html v-if="now >= w.rise" :position="[0, WALL_HEIGHT + 0.4 + w.level * 0.5, 0]" center :z-index-range="[5, 0]">
      <span class="wall">✗ {{ w.label }}</span>
    </Html>
  </TresGroup>
</template>

<style scoped>
.trip,
.wall {
  font: 600 11px/1.2 system-ui, sans-serif;
  padding: 2px 6px;
  border-radius: 4px;
  white-space: nowrap;
  pointer-events: none;
}

.trip {
  max-width: 220px;
  overflow: hidden;
  text-overflow: ellipsis;
  background: #fff3d6;
  color: #5a3b00;
  border-left: 4px solid transparent;
}

.trip.struck,
.wall {
  background: #c0392b;
  color: #fff;
}
</style>
