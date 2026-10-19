<script setup lang="ts">
import type { Card } from '~/composables/useControl'

// What is being attempted, the control that should fire or the claim a tour beat makes, then pass or fail
// with each check once it ends. See docs/architecture.md#dashboard.
defineProps<{ card: Card | undefined }>()

const statusText: Record<Card['status'], string> = { running: 'Running…', passed: 'Passed', failed: 'Failed' }
</script>

<template>
  <section v-if="card" class="card" :class="card.status" aria-label="Scenario card">
    <header>
      <h2>{{ card.title }}</h2>
      <span class="status">{{ statusText[card.status] }}</span>
    </header>
    <p v-if="card.control"><strong>Control:</strong> {{ card.control }}</p>
    <p v-if="card.claim"><strong>Claim:</strong> {{ card.claim }}</p>
    <p v-if="card.pointAt"><strong>Point at:</strong> {{ card.pointAt }}</p>
    <p v-if="card.error" class="error">{{ card.error }}</p>
    <ul>
      <li v-for="c in card.checks" :key="c.name" :class="c.pass ? 'pass' : 'fail'">
        {{ c.pass ? '✓' : '✗' }} {{ c.name }}<template v-if="!c.pass && c.detail">: {{ c.detail }}</template>
      </li>
    </ul>
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
}

h2 {
  margin: 0;
  font-size: 15px;
}

.status {
  font-weight: 600;
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
