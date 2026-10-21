// Whether the "What is this?" introduction is open. It opens by itself on a visitor's first visit, and is
// remembered as seen in their browser only, so it is open again wherever that cannot be kept.

import { ref } from 'vue'

const KEY = 'intro-seen'

function seen(): boolean {
  try {
    return localStorage.getItem(KEY) === '1'
  } catch {
    return false
  }
}

const open = ref(!seen())

export function useIntro() {
  function close() {
    open.value = false
    try {
      localStorage.setItem(KEY, '1')
    } catch {
      // Not remembered; it opens again next visit.
    }
  }
  return { open, show: () => (open.value = true), close }
}
