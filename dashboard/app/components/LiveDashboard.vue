<script setup lang="ts">
import { useBank } from '~/composables/useBank'
import { useControl } from '~/composables/useControl'

// The dashboard on the operator's machine: the run as the control service tells it and the chain reports
// it, with the operator's commands.
const { deployment, lines, card, nextBeat, paused, pace, daily, busy, error, command, setting } = useControl()
const { state, error: chainError } = useBank(deployment)
</script>

<template>
  <BankDashboard :deployment="deployment" :lines="lines" :card="card" :state="state" :error="error ?? chainError">
    <template #panel>
      <ControlPanel
        :deployment="deployment"
        :next-beat="nextBeat"
        :busy="busy"
        :paused="paused"
        :pace="pace"
        :daily="daily"
        :style="{ order: 0 }"
        @command="command"
        @setting="setting"
      />
    </template>
  </BankDashboard>
</template>
