<script setup lang="ts">
import { TresCanvas } from '@tresjs/core'
import { Html } from '@tresjs/cientos'
import { computed } from 'vue'
import { HKD, hkd, OPENING_SETTLEMENT, useBank } from '~/composables/useBank'
import { buildings, houseLots, roads } from '~/town/layout'
import type { Building, Road, Vec3 } from '~/town/layout'

const mapCenter: Vec3 = [3, 0, 2]
const cameraPosition: Vec3 = [30, 30, 30]
const roadWidth = 1
const houseWidth = 1.4
// A house's height grows with its owner's balance, up to this balance.
const tallestHouse = 150_000n * HKD
// The water tower is full at twice the opening settlement balance.
const fullTower = 2n * OPENING_SETTLEMENT

const { state, error } = useBank()

// What each building shows from the chain, under its name.
const figures = computed((): Record<string, string> => {
  const s = state.value
  if (!s) return {}
  return {
    'head-office': s.booksBalance ? 'Books balance' : 'Books do not balance',
    'water-tower': hkd(s.settlement),
    vault: hkd(s.cash.vault),
    branch: `${hkd(s.cash.drawer)} in the drawer`,
    atm: hkd(s.cash.atm),
    'post-office': s.inPayments ? `${hkd(s.inPayments)} waiting` : 'Nothing waiting',
  }
})

const houses = computed(() =>
  houseLots.map((lot, i) => {
    const customer = state.value?.customers[i]
    const share = customer ? Number(customer.balance > tallestHouse ? tallestHouse : customer.balance) / Number(tallestHouse) : 0
    const height = 0.6 + 1.8 * share
    return { lot, customer, height }
  }),
)

const water = computed(() => {
  const tower = buildings.find((b) => b.id === 'water-tower')!
  const settlement = state.value?.settlement ?? 0n
  const share = Math.min(1, Math.max(0, Number(settlement) / Number(fullTower)))
  return { tower, height: Math.max(0.01, tower.size[1] * share) }
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
  <p v-if="error" class="notice">{{ error }}</p>
  <!-- The map changes only when the chain does, so it is drawn on demand rather than every frame. -->
  <TresCanvas clear-color="#eef2f5" render-mode="on-demand" shadows>
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
      <Html v-if="house.customer" :position="[0, house.height + 0.5, 0]" center>
        <span class="label">
          {{ house.customer.name }}
          <small>{{ hkd(house.customer.balance) }}</small>
        </span>
      </Html>
    </TresGroup>
  </TresCanvas>
  </div>
</template>

<style scoped>
.map {
  position: relative;
  height: 100%;
}

.notice {
  position: absolute;
  z-index: 1;
  top: 16px;
  left: 16px;
  right: 16px;
  margin: 0;
  font: 14px/1.4 system-ui, sans-serif;
  color: #5a3b00;
  background: #fff4d6;
  padding: 8px 12px;
  border-radius: 6px;
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
