import { templateCompilerOptions } from '@tresjs/core'

const description =
  'A bank that runs on a blockchain in place of a core banking system: a recorded run of its customers and staff, shown as a small town in 3D, with every refusal, ledger entry and transaction open to inspect.'
const intro =
  'A small simulated bank whose accounts and books are smart contracts instead of a core banking system. Scripted customers and staff go through ordinary banking days, then try to break it: lost phones, a failed ATM, forged slips and an attacker. The chain decides what is allowed, and the books always balance. Watch it play, click any building or person to see what it is and what it has done, and click a line of the story or a check along the top for the signers, the roles checked and the chain events, then follow them to the block explorer.'

// The dashboard runs on the operator's machine or as static files playing back a recorded run, and the bank map
// draws with WebGL, so there is nothing to render on a server.
export default defineNuxtConfig({
  compatibilityDate: '2026-10-01',
  ssr: false,
  // The page draws in the browser, so what a search engine or a link preview reads without running it is
  // here: the title, the description, the preview tags, and the introduction's words in a noscript block.
  app: {
    head: {
      title: 'Agents on Contract Bank',
      htmlAttrs: { lang: 'en' },
      meta: [
        { name: 'description', content: description },
        { property: 'og:type', content: 'website' },
        { property: 'og:title', content: 'Agents on Contract Bank' },
        { property: 'og:description', content: description },
        { name: 'twitter:card', content: 'summary' },
        { name: 'twitter:title', content: 'Agents on Contract Bank' },
        { name: 'twitter:description', content: description },
      ],
      noscript: [
        {
          tagPosition: 'bodyOpen',
          innerHTML: `<h1>Agents on Contract Bank</h1><p>${intro}</p><p>The replay needs JavaScript and WebGL. The source is at <a href="https://github.com/williamchong/agents-on-contract-bank">github.com/williamchong/agents-on-contract-bank</a>.</p>`,
        },
      ],
    },
  },
  devtools: { enabled: false },
  telemetry: false,
  // Set NUXT_PUBLIC_PLAYBACK=1 when building to play back a recorded run instead of driving a live one.
  runtimeConfig: { public: { playback: false } },
  vue: {
    compilerOptions: templateCompilerOptions.template.compilerOptions,
  },
})
