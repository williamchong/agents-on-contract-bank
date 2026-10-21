<script setup lang="ts">
import { computed } from 'vue'
import { usePlayback } from '~/composables/usePlayback'

// The dashboard as static files: a run recorded by `pnpm record`, played back with no chain or services.
const { deployment, lines, card, state, error, chapters, position, total, playing, speed, epoch, play, pause, seek, setSpeed } = usePlayback(
  `${useRuntimeConfig().app.baseURL}recording.json`,
)
const time = computed(() => lines.value.at(-1)?.time)
</script>

<template>
  <BankDashboard :deployment="deployment" :lines="lines" :card="card" :state="state" :error="error" :epoch="epoch">
    <template #panel>
      <PlaybackPanel
        :chapters="chapters"
        :position="position"
        :total="total"
        :playing="playing"
        :speed="speed"
        :time="time"
        :style="{ order: 0 }"
        @play="play"
        @pause="pause"
        @seek="seek"
        @speed="setSpeed"
      />
    </template>
  </BankDashboard>
</template>
