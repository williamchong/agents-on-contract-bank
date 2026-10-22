<script setup lang="ts">
import { TresCanvas } from '@tresjs/core'
import { Html } from '@tresjs/cientos'
import { computed, onBeforeUnmount, ref } from 'vue'
import { Color } from 'three'
import type { BankState } from '~/composables/useBank'
import { HKD, hkd, OPENING_SETTLEMENT } from '~/lib/money'
import type { Deployment, Line } from '~/lib/story'
import { customerId, parse, staffId, staffPresent, type EntityId } from '~/town/entities'
import { framePoints, involved } from '~/town/focus'
import { buildings, houseLots, redTeamSpot, roads, staffPosts } from '~/town/layout'
import type { Building, Road, Vec3 } from '~/town/layout'

// `epoch` moves on when playback jumps, so the traffic starts again with the lines jumped over as history.
// Selecting a building, a house or a person shows what it is and what it has done; the map marks it.
const props = defineProps<{
  deployment: Deployment | undefined
  state: BankState | undefined
  lines: Line[]
  focus?: string
  // The scenario showing, whose story lines the map keeps in view while following.
  scenario?: { from?: number; to?: number }
  epoch?: number
  selected?: EntityId
}>()
const emit = defineEmits<{ select: [id: EntityId] }>()

const showKey = ref(false)
// Following, the camera frames whoever the latest line involves and the rest of the town fades.
const follow = ref(true)

const RED_TEAM = staffId('red team')

const ringRadius = (b: Building) => Math.max(b.size[0], b.size[2]) * 0.8

// The building an adverse scenario concerns, marked with a ring while its card is shown.
const focused = computed(() => buildings.find((b) => b.id === props.focus))

// Where the selected entity stands, marked with a ring of its own: a member of staff at their building.
const selectedAt = computed((): { at: Vec3; radius: number } | undefined => {
  if (!props.selected) return undefined
  if (props.selected === RED_TEAM) return { at: redTeamSpot, radius: 0.35 }
  const p = parse(props.selected)
  if (p.kind === 'customer') {
    const i = houses.value.findIndex((h) => h.customer?.name === p.name)
    return i >= 0 ? { at: houseLots[i]!, radius: 1.2 } : undefined
  }
  const id = p.kind === 'staff' ? staffPosts.find((x) => x.name === p.name)?.building : p.id
  const b = buildings.find((x) => x.id === id)
  return b && { at: b.position, radius: ringRadius(b) }
})

const latest = computed(() => props.lines.findLast((l) => l.kind !== 'operator'))
const followed = computed(() => {
  const d = props.deployment
  return follow.value && d && latest.value ? involved(d, latest.value) : new Set<EntityId>()
})
const frame = computed(() => {
  const d = props.deployment
  return d ? [...followed.value].flatMap((id) => framePoints(d, id)) : []
})
// Everything the scenario showing has involved so far, while the latest line belongs to it.
const inScenario = computed(() => {
  const ids = new Set<EntityId>()
  const d = props.deployment
  const { from, to } = props.scenario ?? {}
  const seq = latest.value?.seq
  if (!d || !followed.value.size || from === undefined || seq === undefined || seq < from || (to !== undefined && seq > to)) return ids
  for (const line of props.lines) if (line.seq >= from) for (const id of involved(d, line)) ids.add(id)
  return ids
})
// While following, the latest line's entities and the selection stay in full colour, the rest of the
// scenario and the building it concerns fade a little, and the rest of the town fades well back.
type Tier = 'step' | 'scenario' | 'other'
function tier(id: EntityId | undefined): Tier {
  if (!followed.value.size) return 'step'
  if (id && (followed.value.has(id) || id === props.selected)) return 'step'
  if (id && (inScenario.value.has(id) || id === props.focus)) return 'scenario'
  return 'other'
}
const GROUND = '#cfe0c3'
const fade: Record<Tier, number> = { step: 0, scenario: 0.35, other: 0.75 }
// A faded colour, part way to the ground's, so the town keeps its shape behind what is happening.
function shade(color: string, id: EntityId | undefined): string {
  const t = tier(id)
  return t === 'step' ? color : `#${new Color(color).lerp(new Color(GROUND), fade[t]).getHexString()}`
}

function labelClass(id: EntityId | undefined) {
  return [tier(id), { on: !!id && props.selected === id }]
}

function pick(id: EntityId, e?: { stopPropagation?: () => void }) {
  e?.stopPropagation?.()
  emit('select', id)
}

function hover(over: boolean) {
  document.body.style.cursor = over ? 'pointer' : ''
}
// A mesh that goes while pointed at never reports the pointer leaving it.
onBeforeUnmount(() => hover(false))

const mapCenter: Vec3 = [3, 0, 2]
const cameraPosition: Vec3 = [30, 30, 30]
const roadWidth = 1
const houseWidth = 1.4
// A house's height grows with its owner's balance, up to this balance.
const tallestHouse = 150_000n * HKD
// The water tower is full at twice the opening settlement balance.
const fullTower = 2n * OPENING_SETTLEMENT

// Both tellers' drawers: whoever holds the role, the other's has gone back to the vault.
function drawers(s: BankState): bigint {
  return s.cash.drawer + s.cash.replacementDrawer
}

// What each building shows from the chain, under its name: one short figure, the rest in its details.
const figures = computed((): Record<string, string> => {
  const s = props.state
  if (!s) return {}
  return {
    'head-office': s.booksBalance ? 'Books balance' : 'Books do not balance',
    'water-tower': hkd(s.ledger.Settlement),
    vault: hkd(s.cash.vault),
    branch: s.awaitingApproval ? `${hkd(s.awaitingApproval)} awaiting approval` : `${hkd(drawers(s))} in the drawers`,
    atm: hkd(s.cash.atm),
    'post-office': s.inPayments ? `${hkd(s.inPayments)} waiting` : 'Nothing waiting',
  }
})

const houses = computed(() =>
  houseLots.map((lot, i) => {
    const customer = props.state?.customers[i]
    const share = customer ? Number(customer.balance > tallestHouse ? tallestHouse : customer.balance) / Number(tallestHouse) : 0
    const height = 0.6 + 1.8 * share
    return { lot, customer, height, id: customer && customerId(customer.name) }
  }),
)

const water = computed(() => {
  const tower = buildings.find((b) => b.id === 'water-tower')!
  const settlement = props.state?.ledger.Settlement ?? 0n
  const share = Math.min(1, Math.max(0, Number(settlement) / Number(fullTower)))
  return { tower, height: Math.max(0.01, tower.size[1] * share) }
})

// How many staff work in each building now: one whose role was revoked leaves, and one granted a role
// arrives. The replacement teller has none until the branch grants it.
const present = computed(() => (props.deployment ? staffPresent(props.deployment, props.lines) : new Set<string>()))
const staffCount = computed(() => {
  const counts: Record<string, number> = {}
  for (const p of staffPosts) if (p.building && present.value.has(p.name)) counts[p.building] = (counts[p.building] ?? 0) + 1
  return counts
})

const key = [
  { color: '#f2e6d0', text: 'A house is a customer; it grows with their balance' },
  { color: '#2f7fc1', text: 'The water is the bank’s money at the clearing system' },
  { color: '#f2b134', text: 'Gold coins are money moving' },
  { color: '#c0392b', text: 'A red bar is an attempt the chain refused' },
  { color: '#c0392b', text: 'The red figure is the red team, an attacker' },
]

function isTower(b: Building) {
  return b.shape === 'tower'
}

function roadPosition({ from, to }: Road): Vec3 {
  return [(from[0] + to[0]) / 2, 0.01, (from[1] + to[1]) / 2]
}

// Roads run along one axis, so the other axis has no extent and takes the road's width.
function roadSize({ from, to }: Road): Vec3 {
  return [Math.abs(to[0] - from[0]) || roadWidth, 0.02, Math.abs(to[1] - from[1]) || roadWidth]
}
</script>

<template>
  <div class="map">
  <!-- Vans move between blocks' states, so the map draws every frame. -->
  <TresCanvas clear-color="#eef2f5" render-mode="always" shadows>
    <IsometricCamera
      :position="cameraPosition"
      :target="mapCenter"
      :view-height="26"
      :min-view-width="31"
      :frame="frame"
      :min-frame-height="9"
    />
    <TresAmbientLight :intensity="1.6" />
    <!-- three's default shadow camera covers about 10 units; this one covers the whole map. -->
    <TresDirectionalLight
      :position="[10, 20, 8]"
      :intensity="1.8"
      cast-shadow
      :shadow-camera-left="-24"
      :shadow-camera-right="24"
      :shadow-camera-top="24"
      :shadow-camera-bottom="-24"
      :shadow-bias="-0.001"
    />

    <TresMesh :rotation-x="-Math.PI / 2" :position="mapCenter" receive-shadow>
      <TresPlaneGeometry :args="[40, 28]" />
      <TresMeshStandardMaterial :color="GROUND" />
    </TresMesh>

    <TresMesh v-for="(road, i) in roads" :key="i" :position="roadPosition(road)" receive-shadow>
      <TresBoxGeometry :args="roadSize(road)" />
      <TresMeshStandardMaterial color="#8a8f94" />
    </TresMesh>

    <TresGroup v-for="building in buildings" :key="building.id" :position="building.position">
      <TresMesh
        :position-y="building.size[1] / 2"
        cast-shadow
        receive-shadow
        @click="pick(building.id, $event)"
        @pointerenter="hover(true)"
        @pointerleave="hover(false)"
      >
        <TresCylinderGeometry
          v-if="isTower(building)"
          :args="[building.size[0] / 2, building.size[0] / 2, building.size[1], 16]"
        />
        <TresBoxGeometry v-else :args="building.size" />
        <TresMeshStandardMaterial :color="shade(building.color, building.id)" :transparent="isTower(building)" :opacity="isTower(building) ? 0.35 : 1" />
      </TresMesh>
      <Html :position="[0, building.size[1] + 0.6, 0]" center :z-index-range="[5, 0]">
        <button class="label" :class="labelClass(building.id)" @click="pick(building.id)">
          {{ building.label }}<span v-if="staffCount[building.id]" class="staff" :title="`${staffCount[building.id]} staff work here`">👥 {{ staffCount[building.id] }}</span>
          <small v-if="figures[building.id]"><MoneyText :text="figures[building.id]!" /></small>
        </button>
      </Html>
    </TresGroup>

    <!-- The water in the tower is the settlement account's balance. -->
    <TresMesh :position="[water.tower.position[0], water.height / 2, water.tower.position[2]]">
      <TresCylinderGeometry :args="[water.tower.size[0] / 2 - 0.08, water.tower.size[0] / 2 - 0.08, water.height, 16]" />
      <TresMeshStandardMaterial :color="shade('#2f7fc1', 'water-tower')" />
    </TresMesh>

    <TresGroup v-for="(house, i) in houses" :key="i" :position="[house.lot[0], 0, house.lot[2]]">
      <TresMesh
        :position-y="house.height / 2"
        cast-shadow
        @click="house.id && pick(house.id, $event)"
        @pointerenter="hover(!!house.id)"
        @pointerleave="hover(false)"
      >
        <TresBoxGeometry :args="[houseWidth, house.height, houseWidth]" />
        <TresMeshStandardMaterial :color="shade('#f2e6d0', house.id)" />
      </TresMesh>
      <!-- Html keeps the slot it was first rendered with, so the label reads the live list, not this house. -->
      <Html v-if="house.customer" :position="[0, house.height + 0.5, 0]" center :z-index-range="[5, 0]">
        <button v-if="houses[i]?.id" class="label" :class="labelClass(houses[i]!.id)" @click="pick(houses[i]!.id!)">
          {{ houses[i]!.customer!.name }}
          <small class="money">{{ hkd(houses[i]!.customer!.balance) }}</small>
        </button>
      </Html>
    </TresGroup>
    <TresGroup v-if="present.has('red team')" :position="redTeamSpot">
      <TresMesh
        :position-y="0.45"
        cast-shadow
        @click="pick(RED_TEAM, $event)"
        @pointerenter="hover(true)"
        @pointerleave="hover(false)"
      >
        <TresCapsuleGeometry :args="[0.2, 0.5, 4, 8]" />
        <TresMeshStandardMaterial :color="shade('#c0392b', RED_TEAM)" />
      </TresMesh>
      <Html :position="[0, 1.25, 0]" center :z-index-range="[5, 0]">
        <button class="label" :class="labelClass(RED_TEAM)" @click="pick(RED_TEAM)">Red team</button>
      </Html>
    </TresGroup>

    <TresMesh v-if="selectedAt" :position="[selectedAt.at[0], 0.06, selectedAt.at[2]]" :rotation-x="-Math.PI / 2">
      <TresRingGeometry :args="[selectedAt.radius, selectedAt.radius + 0.18, 40]" />
      <TresMeshBasicMaterial color="#2b3540" />
    </TresMesh>

    <TresMesh v-if="focused" :position="[focused.position[0], 0.05, focused.position[2]]" :rotation-x="-Math.PI / 2">
      <TresRingGeometry :args="[ringRadius(focused), ringRadius(focused) + 0.35, 48]" />
      <TresMeshBasicMaterial color="#e8a33d" />
    </TresMesh>

    <MapTraffic v-if="deployment" :key="epoch" :deployment="deployment" :lines="lines" />
  </TresCanvas>
  <div class="overlay">
    <slot name="caption" />
    <div class="key">
      <button
        class="key-toggle"
        :aria-pressed="follow"
        title="Frame whoever the latest line involves, and fade the rest of the town"
        @click="follow = !follow"
      >
        {{ follow ? 'Show whole town' : 'Follow the action' }}
      </button>
      <button class="key-toggle" :aria-expanded="showKey" @click="showKey = !showKey">{{ showKey ? 'Hide key' : 'Key' }}</button>
      <ul v-if="showKey">
        <li v-for="k in key" :key="k.text"><span class="swatch" :style="{ background: k.color }" />{{ k.text }}</li>
        <li class="hint">Click a building, a house or a person to see what it is and what it has done.</li>
      </ul>
    </div>
  </div>
  </div>
</template>

<style scoped>
.map {
  position: relative;
  height: 100%;
  /* Following, the camera frames part of the town; labels of the rest stay inside the map. */
  overflow: hidden;
}


.overlay {
  position: absolute;
  left: 12px;
  right: 12px;
  bottom: 12px;
  display: flex;
  align-items: flex-end;
  gap: 12px;
  pointer-events: none;
}

.overlay > * {
  pointer-events: auto;
}

.key {
  margin-left: auto;
  font: 12px/1.4 system-ui, sans-serif;
  color: #2b3540;
  text-align: right;
}

.key-toggle {
  font: inherit;
  padding: 4px 10px;
  border-radius: 6px;
  border: 1px solid #c9d1d8;
  background: rgb(255 255 255 / 90%);
  color: inherit;
  cursor: pointer;
}

.key ul {
  margin: 0 0 6px;
  padding: 8px 10px;
  list-style: none;
  text-align: left;
  background: rgb(255 255 255 / 92%);
  border-radius: 6px;
  max-width: 240px;
}

.key li {
  display: flex;
  align-items: center;
  gap: 6px;
  margin: 2px 0;
}

.key .hint {
  margin-top: 6px;
  color: #66727d;
}

.swatch {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  flex: none;
}

.staff {
  margin-left: 6px;
  font-weight: 400;
  color: #55606b;
}

.label small {
  display: block;
  font-weight: 400;
  margin-top: 2px;
}

.label {
  display: inline-block;
  font: 600 12px/1 system-ui, sans-serif;
  color: #2b3540;
  background: rgb(255 255 255 / 80%);
  padding: 2px 6px;
  border: 0;
  border-radius: 4px;
  white-space: nowrap;
  cursor: pointer;
  text-align: center;
  transition: opacity 0.4s;
}

/* On a phone the figures under each name would cover the town; a building's details still show them. */
@media (max-width: 600px) {
  .label small {
    display: none;
  }
}

/* Map labels are always light, so money on them takes the light theme's colour. */
.label :deep(.money) {
  color: #8a5a00;
}

.label.on {
  outline: 2px solid #2b3540;
}

.label.scenario {
  opacity: 0.7;
}

.label.other {
  opacity: 0.3;
}
</style>
