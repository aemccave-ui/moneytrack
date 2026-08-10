export const SWIPE_OPEN_EVENT = 'moneytrack:swipe-open'

let scopeSequence = 0

export function nextSwipeScope(prefix) {
  scopeSequence += 1
  return `${prefix}-${scopeSequence}`
}

export function announceSwipeOpen(key) {
  window.dispatchEvent(new CustomEvent(SWIPE_OPEN_EVENT, { detail: { key } }))
}
