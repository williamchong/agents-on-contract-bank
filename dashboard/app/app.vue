<script setup lang="ts">
import { useBank } from '~/composables/useBank'
import { useControl } from '~/composables/useControl'

// The dashboard: the invariant strip across the top, the bank map, the story view with its waiting strip,
// the scenario card, the balance sheet and the control panel. See docs/architecture.md#dashboard.
const { deployment, lines, card, nextBeat, busy, error, command } = useControl()
const { state, error: chainError } = useBank(deployment)
</script>

<template>
  <div class="dashboard">
    <InvariantStrip :state="state" />
    <p v-if="error || chainError" class="notice" role="status">{{ error ?? chainError }}</p>
    <main>
      <div class="map">
        <BankMap :deployment="deployment" :state="state" :lines="lines" :focus="card?.building" />
      </div>
      <aside>
        <ControlPanel :deployment="deployment" :next-beat="nextBeat" :busy="busy" @command="command" />
        <ScenarioCard :card="card" />
        <WaitingStrip :lines="lines" :deployment="deployment" />
        <StoryView :lines="lines" :deployment="deployment" />
        <BalanceSheet :state="state" />
      </aside>
    </main>
  </div>
</template>

<style>
:root {
  --bg: #eef2f5;
  --panel: #ffffff;
  --chip: #f3f5f7;
  --line: #dde3e8;
  --ink: #1f2a33;
  --muted: #66727d;
  --good: #1e7d4f;
  --bad: #b3261e;
  --bad-bg: #fbeceb;
  --wait: #d9922b;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #12171c;
    --panel: #1a2129;
    --chip: #222b34;
    --line: #2e3842;
    --ink: #e4e9ee;
    --muted: #9aa6b1;
    --good: #5cc28f;
    --bad: #ff8a80;
    --bad-bg: #3a1f1d;
    --wait: #f0b45a;
  }
}

html,
body {
  margin: 0;
  height: 100%;
  background: var(--bg);
  color: var(--ink);
  font-family: system-ui, sans-serif;
}

.dashboard {
  display: flex;
  flex-direction: column;
  height: 100vh;
}

.notice {
  margin: 0;
  padding: 8px 16px;
  background: #fff4d6;
  color: #5a3b00;
  font-size: 14px;
}

main {
  flex: 1;
  display: grid;
  grid-template-columns: minmax(0, 1fr) 420px;
  min-height: 0;
}

.map {
  min-height: 0;
}

aside {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 12px 16px;
  overflow-y: auto;
  background: var(--panel);
  border-left: 1px solid var(--line);
}

@media (max-width: 900px) {
  main {
    grid-template-columns: 1fr;
    grid-template-rows: 55vh auto;
  }

  aside {
    border-left: none;
    border-top: 1px solid var(--line);
  }
}
</style>
