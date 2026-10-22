<script setup lang="ts">
// The dashboard: live on the operator's machine, or, built with NUXT_PUBLIC_PLAYBACK set, a recorded run
// played back from static files. See docs/architecture.md#dashboard.
const playback = Boolean(useRuntimeConfig().public.playback)
</script>

<template>
  <UApp>
    <PlaybackDashboard v-if="playback" />
    <LiveDashboard v-else />
  </UApp>
</template>
