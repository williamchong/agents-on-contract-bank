<script setup lang="ts">
import { computed } from 'vue'
import { useIntro } from '~/composables/useIntro'
import { chain } from '~/town/entities'

// What the page is, for a first-time visitor: the bank in two sentences and the three ways to look at it,
// from watching to reading the contracts, and the chain the run was recorded on. The same words are in the
// page's HTML for search engines; see nuxt.config.ts.
const props = defineProps<{ chainId: number | undefined }>()
const { open, close } = useIntro()

// Said once the recording is loaded, so the chain is known.
const recorded = computed(() => {
  if (props.chainId === undefined) return undefined
  const c = chain(props.chainId)
  if (!c) return 'No real money. This run was recorded on a local test chain.'
  return `No real money. This run was recorded on ${c.name}, a public ${c.test ? 'test ' : ''}chain, so every step can be checked on its block explorer.`
})
</script>

<template>
  <UModal :open="open" title="A bank that runs on a blockchain" :ui="{ title: 'text-xl', footer: 'gap-4' }" @update:open="(o) => o || close()">
    <template #body>
      <div class="space-y-2.5 text-sm/relaxed">
        <p>
          A small simulated bank whose accounts and books are smart contracts instead of a core banking system. Scripted customers and
          staff go through ordinary banking days, then try to break it: lost phones, a failed ATM, forged slips and an attacker. The chain
          decides what is allowed, and the books always balance.
        </p>
        <ul class="list-disc space-y-1 pl-5">
          <li><strong>Watch.</strong> It plays by itself, and the caption at the bottom of the map says what is happening.</li>
          <li><strong>Explore.</strong> Click any building, house or person to see what it is, what it holds and what it has done.</li>
          <li><strong>Dig in.</strong> Click a line of the story or a check along the top for the signers, the roles checked and the chain events, then follow them to the block explorer.</li>
        </ul>
        <p v-if="recorded" class="text-xs text-muted">{{ recorded }}</p>
      </div>
    </template>
    <template #footer>
      <UButton label="Start watching" @click="close" />
      <ULink to="https://github.com/williamchong/agents-on-contract-bank" target="_blank" class="text-sm underline">Source on GitHub</ULink>
    </template>
  </UModal>
</template>
