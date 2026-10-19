import { templateCompilerOptions } from '@tresjs/core'

// The dashboard runs on the operator's machine only, and the bank map draws with WebGL, so there is nothing to render on a server.
export default defineNuxtConfig({
  compatibilityDate: '2026-10-01',
  ssr: false,
  devtools: { enabled: false },
  telemetry: false,
  vue: {
    compilerOptions: templateCompilerOptions.template.compilerOptions,
  },
})
