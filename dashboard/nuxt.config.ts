import { templateCompilerOptions } from '@tresjs/core'

// The dashboard runs on the operator's machine or as static files playing back a recorded run, and the bank map
// draws with WebGL, so there is nothing to render on a server.
export default defineNuxtConfig({
  compatibilityDate: '2026-10-01',
  ssr: false,
  app: {
    head: {
      title: 'Agents on Contract Bank',
      meta: [
        {
          name: 'description',
          content:
            'A bank that runs on a blockchain in place of a core banking system, with AI agents as its customers and staff, shown as a small town in 3D.',
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
