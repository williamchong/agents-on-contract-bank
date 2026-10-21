<script setup lang="ts">
import { computed } from 'vue'
import type { Card } from '~/composables/useControl'

// The scene being played, in one plain sentence: what an adverse scenario attempts or the claim a tour beat
// makes, then pass or fail once it ends. The control it tests, what to point at and each check are a click
// away. See docs/architecture.md#dashboard.
const props = defineProps<{ card: Card | undefined }>()

const statusText: Record<Card['status'], string> = { running: 'Playing', passed: 'Passed', failed: 'Failed' }
const passed = computed(() => props.card?.checks.filter((c) => c.pass).length ?? 0)
</script>

<template>
  <section v-if="card" class="card" :class="card.status" aria-label="Scenario card">
    <header>
      <h2>{{ card.title }}</h2>
      <span class="status">{{ statusText[card.status] }}</span>
    </header>
    <p class="lead">{{ card.summary ?? card.claim }}</p>
    <p v-if="card.error" class="error">{{ card.error }}</p>
    <details v-if="card.control || card.pointAt || card.checks.length || (card.summary && card.claim)">
      <summary>
        <template v-if="card.checks.length">{{ passed }} of {{ card.checks.length }} checks passed</template>
        <template v-else>What it tests</template>
      </summary>
      <p v-if="card.control"><strong>Control tested:</strong> {{ card.control }}</p>
      <p v-if="card.summary && card.claim"><strong>Claim:</strong> {{ card.claim }}</p>
      <p v-if="card.pointAt"><strong>Look at:</strong> {{ card.pointAt }}</p>
      <ul>
        <li v-for="c in card.checks" :key="c.name" :class="c.pass ? 'pass' : 'fail'">
          {{ c.pass ? '✓' : '✗' }} {{ c.name }}<template v-if="!c.pass && c.detail">: {{ c.detail }}</template>
        </li>
      </ul>
    </details>
  </section>
</template>

<style scoped>
.card {
  border: 1px solid var(--line);
  border-left: 4px solid var(--wait);
  padding: 8px 10px;
  background: var(--panel);
  font-size: 13px;
}

.passed {
  border-left-color: var(--good);
}

.failed {
  border-left-color: var(--bad);
}

header {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 8px;
}

h2 {
  margin: 0;
  font-size: 15px;
}

.status {
  font-weight: 600;
  flex: none;
}

.passed .status {
  color: var(--good);
}

.failed .status {
  color: var(--bad);
}

.lead {
  margin: 4px 0 0;
  line-height: 1.45;
}

details {
  margin-top: 6px;
}

summary {
  cursor: pointer;
  color: var(--muted);
  font-size: 12px;
}

p {
  margin: 4px 0;
}

ul {
  margin: 6px 0 0;
  padding: 0;
  list-style: none;
}

.pass {
  color: var(--good);
}

.fail,
.error {
  color: var(--bad);
}
</style>
