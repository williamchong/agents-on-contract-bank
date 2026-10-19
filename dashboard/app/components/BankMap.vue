<script setup lang="ts">
import { TresCanvas } from '@tresjs/core'
import { Html } from '@tresjs/cientos'
import { buildings, houseLots, roads } from '~/town/layout'
import type { Road, Vec3 } from '~/town/layout'

const mapCenter: Vec3 = [3, 0, 2]
const cameraPosition: Vec3 = [30, 30, 30]
const roadWidth = 1
const houseSize: Vec3 = [1.4, 1.2, 1.4]

function roadPosition({ from, to }: Road): Vec3 {
  return [(from[0] + to[0]) / 2, 0.01, (from[1] + to[1]) / 2]
}

// Roads run along one axis, so the other axis has no extent and takes the road's width.
function roadSize({ from, to }: Road): Vec3 {
  return [Math.abs(to[0] - from[0]) || roadWidth, 0.02, Math.abs(to[1] - from[1]) || roadWidth]
}
</script>

<template>
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
          v-if="building.shape === 'tower'"
          :args="[building.size[0] / 2, building.size[0] / 2, building.size[1], 16]"
        />
        <TresBoxGeometry v-else :args="building.size" />
        <TresMeshStandardMaterial :color="building.color" />
      </TresMesh>
      <Html :position="[0, building.size[1] + 0.6, 0]" center>
        <span class="label">{{ building.label }}</span>
      </Html>
    </TresGroup>

    <TresMesh v-for="(lot, i) in houseLots" :key="i" :position="[lot[0], houseSize[1] / 2, lot[2]]" cast-shadow>
      <TresBoxGeometry :args="houseSize" />
      <TresMeshStandardMaterial color="#f2e6d0" />
    </TresMesh>
  </TresCanvas>
</template>

<style scoped>
.label {
  font: 600 12px/1 system-ui, sans-serif;
  color: #2b3540;
  background: rgb(255 255 255 / 80%);
  padding: 2px 6px;
  border-radius: 4px;
  white-space: nowrap;
  pointer-events: none;
}
</style>
