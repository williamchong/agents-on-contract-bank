<script setup lang="ts">
// The dashboard: live on the operator's machine, or, built with NUXT_PUBLIC_PLAYBACK set, a recorded run
// played back from static files. See docs/architecture.md#dashboard.
const playback = Boolean(useRuntimeConfig().public.playback)
</script>

<template>
  <PlaybackDashboard v-if="playback" />
  <LiveDashboard v-else />
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

/* Money and who took part, by what they do (see app/town/palette.ts). The map's overlays are always light,
   so names and money on them keep the light theme's colours. */
:root,
.on-light {
  --money: #8a5a00;
  --tone-customer: #2f63a8;
  --tone-branch: #c4560e;
  --tone-head-office: #7448b0;
  --tone-payments: #0f7c70;
  --tone-attacker: #b3261e;
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
    --money: #f2c46b;
    --tone-customer: #8bb8f0;
    --tone-branch: #f59a52;
    --tone-head-office: #c4a6f0;
    --tone-payments: #4fc9b8;
    --tone-attacker: #ff7b72;
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

/* Whoever took part in a line reads in the colour of what they do. */
.tone-customer { --tone: var(--tone-customer); }
.tone-branch { --tone: var(--tone-branch); }
.tone-head-office { --tone: var(--tone-head-office); }
.tone-payments { --tone: var(--tone-payments); }
.tone-attacker { --tone: var(--tone-attacker); }

.who {
  color: var(--tone, inherit);
  font-weight: 600;
}

/* Every amount of money reads apart from the words around it. */
.money {
  color: var(--money);
  font-weight: 600;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
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
