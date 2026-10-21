<script setup lang="ts">
import { computed, watch } from 'vue'
import { useIntro } from '~/composables/useIntro'
import { usePlayback } from '~/composables/usePlayback'

// The dashboard as static files: a run recorded by `pnpm record`, played back with no chain or services.
// It plays by itself, after the introduction on a first visit.
const intro = useIntro()
const { deployment, lines, card, state, error, chapters, position, total, playing, speed, epoch, play, pause, seek, setSpeed } = usePlayback(
  `${useRuntimeConfig().app.baseURL}recording.json`,
  () => !intro.open.value,
)
watch(intro.open, (open) => {
  if (!open && position.value === 0 && !playing.value) play()
})
const time = computed(() => lines.value.at(-1)?.time)
</script>

<template>
  <BankDashboard :deployment="deployment" :lines="lines" :card="card" :state="state" :error="error" :epoch="epoch" intro>
    <template #bar>
      <PlaybackBar
        :chapters="chapters"
        :position="position"
        :total="total"
        :playing="playing"
        :speed="speed"
        :time="time"
        @play="play"
        @pause="pause"
        @seek="seek"
        @speed="setSpeed"
      />
    </template>
  </BankDashboard>
</template>
