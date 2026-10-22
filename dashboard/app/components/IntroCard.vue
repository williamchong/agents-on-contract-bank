<script setup lang="ts">
import { useIntro } from '~/composables/useIntro'

// What the page is, for a first-time visitor: the bank in two sentences and the three ways to look at it,
// from watching to reading the contracts. The same words are in the page's HTML for search engines; see
// nuxt.config.ts.
const { open, close } = useIntro()
</script>

<template>
  <div v-if="open" class="backdrop" @click.self="close">
    <section class="intro" role="dialog" aria-modal="true" aria-labelledby="intro-title">
      <h2 id="intro-title">A bank that runs on a blockchain</h2>
      <p>
        A small simulated bank whose accounts and books are smart contracts instead of a core banking system. Scripted customers and
        staff go through ordinary banking days, then try to break it: lost phones, a failed ATM, forged slips and an attacker. The chain
        decides what is allowed, and the books always balance.
      </p>
      <ul>
        <li><strong>Watch.</strong> It plays by itself, and the caption at the bottom of the map says what is happening.</li>
        <li><strong>Explore.</strong> Click any building, house or person to see what it is, what it holds and what it has done.</li>
        <li><strong>Dig in.</strong> Click a line of the story or a check along the top for the signers, the roles checked and the chain events, then follow them to the block explorer.</li>
      </ul>
      <p class="note">No real money. This run was recorded on a local test chain.</p>
      <div class="actions">
        <button class="start" @click="close">Start watching</button>
        <a href="https://github.com/williamchong/agents-on-contract-bank" target="_blank" rel="noopener">Source on GitHub</a>
      </div>
    </section>
  </div>
</template>

<style scoped>
.backdrop {
  position: fixed;
  inset: 0;
  z-index: 10;
  display: grid;
  place-items: center;
  padding: 16px;
  background: rgb(10 14 18 / 45%);
}

.intro {
  max-width: 520px;
  max-height: calc(100vh - 32px);
  overflow-y: auto;
  padding: 20px 22px;
  border-radius: 12px;
  background: var(--panel);
  color: var(--ink);
  font-size: 14px;
  line-height: 1.5;
  box-shadow: 0 10px 40px rgb(0 0 0 / 30%);
}

h2 {
  margin: 0 0 8px;
  font-size: 20px;
}

p {
  margin: 0 0 10px;
}

ul {
  margin: 0 0 10px;
  padding-left: 18px;
}

li {
  margin-bottom: 4px;
}

.note {
  color: var(--muted);
  font-size: 12px;
}

.actions {
  display: flex;
  align-items: center;
  gap: 16px;
  margin-top: 14px;
}

.start {
  font: inherit;
  font-weight: 600;
  padding: 8px 16px;
  border-radius: 8px;
  border: 0;
  background: var(--ink);
  color: var(--panel);
  cursor: pointer;
}

a {
  color: var(--muted);
}
</style>
