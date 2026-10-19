<script setup lang="ts">
import { TresCanvas } from '@tresjs/core'
import { Html } from '@tresjs/cientos'
import { computed } from 'vue'
import type { BankState } from '~/composables/useBank'
import { HKD, hkd, OPENING_SETTLEMENT } from '~/lib/money'
import type { Deployment, Line } from '~/lib/story'
import { buildings, houseLots, roads, staffPosts } from '~/town/layout'
import type { Building, Road, Vec3 } from '~/town/layout'

const props = defineProps<{ deployment: Deployment | undefined; state: BankState | undefined; lines: Line[]; focus?: string }>()

const legend = staffPosts.map((p) => `${p.code} ${p.name}`).join(' · ')

// The building an adverse scenario concerns, marked with a ring while its card is shown.
const focused = computed(() => buildings.find((b) => b.id === props.focus))

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

// What each building shows from the chain, under its name.
const figures = computed((): Record<string, string> => {
  const s = props.state
  if (!s) return {}
  return {
    'head-office': s.booksBalance ? 'Books balance' : 'Books do not balance',
    'water-tower': hkd(s.ledger.Settlement),
    vault: hkd(s.cash.vault),
    branch: s.awaitingApproval
      ? `${hkd(drawers(s))} in the drawers, ${hkd(s.awaitingApproval)} awaiting approval`
      : `${hkd(drawers(s))} in the drawers`,
    atm: hkd(s.cash.atm),
    'post-office': s.inPayments ? `${hkd(s.inPayments)} waiting` : 'Nothing waiting',
  }
})

const houses = computed(() =>
  houseLots.map((lot, i) => {
    const customer = props.state?.customers[i]
    const share = customer ? Number(customer.balance > tallestHouse ? tallestHouse : customer.balance) / Number(tallestHouse) : 0
    const height = 0.6 + 1.8 * share
    return { lot, customer, height }
  }),
)

const water = computed(() => {
  const tower = buildings.find((b) => b.id === 'water-tower')!
  const settlement = props.state?.ledger.Settlement ?? 0n
  const share = Math.min(1, Math.max(0, Number(settlement) / Number(fullTower)))
  return { tower, height: Math.max(0.01, tower.size[1] * share) }
})

// Staff and machines as figures at their posts, each marked with its role; one whose role was revoked
// leaves, and one granted a role arrives. The replacement teller has none until the branch grants it.
const staffFigures = computed(() => {
  const d = props.deployment
  if (!d) return []
  const present = new Set(Object.keys(d.staff).filter((n) => n !== 'replacement teller' && n !== 'ATM'))
  const byAccount = new Map(Object.entries(d.staff).map(([n, a]) => [a.toLowerCase(), n]))
  for (const line of props.lines) {
    for (const e of line.events) {
      const who = byAccount.get(String(e.args.account ?? '').toLowerCase())
      if (!who || e.contract !== 'StaffRoles') continue
      if (e.name === 'Granted') present.add(who)
      if (e.name === 'Revoked') present.delete(who)
    }
  }
  return staffPosts.filter((p) => present.has(p.name))
})

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
    <IsometricCamera :position="cameraPosition" :target="mapCenter" :view-height="26" />
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
      <TresMeshStandardMaterial color="#cfe0c3" />
    </TresMesh>

    <TresMesh v-for="(road, i) in roads" :key="i" :position="roadPosition(road)" receive-shadow>
      <TresBoxGeometry :args="roadSize(road)" />
      <TresMeshStandardMaterial color="#8a8f94" />
    </TresMesh>

    <TresGroup v-for="building in buildings" :key="building.id" :position="building.position">
      <TresMesh :position-y="building.size[1] / 2" cast-shadow receive-shadow>
        <TresCylinderGeometry
          v-if="isTower(building)"
          :args="[building.size[0] / 2, building.size[0] / 2, building.size[1], 16]"
        />
        <TresBoxGeometry v-else :args="building.size" />
        <TresMeshStandardMaterial :color="building.color" :transparent="isTower(building)" :opacity="isTower(building) ? 0.35 : 1" />
      </TresMesh>
      <Html :position="[0, building.size[1] + 0.6, 0]" center>
        <span class="label">
          {{ building.label }}
          <small v-if="figures[building.id]">{{ figures[building.id] }}</small>
        </span>
      </Html>
    </TresGroup>

    <!-- The water in the tower is the settlement account's balance. -->
    <TresMesh :position="[water.tower.position[0], water.height / 2, water.tower.position[2]]">
      <TresCylinderGeometry :args="[water.tower.size[0] / 2 - 0.08, water.tower.size[0] / 2 - 0.08, water.height, 16]" />
      <TresMeshStandardMaterial color="#2f7fc1" />
    </TresMesh>

    <TresGroup v-for="(house, i) in houses" :key="i" :position="[house.lot[0], 0, house.lot[2]]">
      <TresMesh :position-y="house.height / 2" cast-shadow>
        <TresBoxGeometry :args="[houseWidth, house.height, houseWidth]" />
        <TresMeshStandardMaterial color="#f2e6d0" />
      </TresMesh>
      <!-- Html keeps the slot it was first rendered with, so the label reads the live list, not this house. -->
      <Html v-if="house.customer" :position="[0, house.height + 0.5, 0]" center>
        <span class="label">
          {{ houses[i]?.customer?.name }}
          <small>{{ houses[i]?.customer ? hkd(houses[i]!.customer!.balance) : '' }}</small>
        </span>
      </Html>
    </TresGroup>
    <TresGroup v-for="f in staffFigures" :key="f.name" :position="f.position">
      <TresMesh :position-y="0.45" cast-shadow>
        <TresCapsuleGeometry :args="[0.18, 0.5, 4, 8]" />
        <TresMeshStandardMaterial :color="f.color" />
      </TresMesh>
      <Html :position="[0, 1.15, 0]" center>
        <span class="figure" :title="f.name">{{ f.code }}</span>
      </Html>
    </TresGroup>

    <TresMesh v-if="focused" :position="[focused.position[0], 0.05, focused.position[2]]" :rotation-x="-Math.PI / 2">
      <TresRingGeometry :args="[Math.max(focused.size[0], focused.size[2]) * 0.8, Math.max(focused.size[0], focused.size[2]) * 0.8 + 0.35, 48]" />
      <TresMeshBasicMaterial color="#e8a33d" />
    </TresMesh>

    <MapTraffic v-if="deployment" :deployment="deployment" :lines="lines" />
  </TresCanvas>
  <p class="legend">Staff: {{ legend }}</p>
  </div>
</template>

<style scoped>
.map {
  position: relative;
  height: 100%;
}


.legend {
  position: absolute;
  left: 12px;
  bottom: 8px;
  right: 12px;
  margin: 0;
  font: 11px/1.4 system-ui, sans-serif;
  color: #4a5560;
  pointer-events: none;
}

.figure {
  font: 500 10px/1 system-ui, sans-serif;
  color: #2b3540;
  background: rgb(255 255 255 / 70%);
  padding: 1px 4px;
  border-radius: 3px;
  white-space: nowrap;
  pointer-events: none;
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
  border-radius: 4px;
  white-space: nowrap;
  pointer-events: none;
}
</style>
