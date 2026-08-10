const SCROLL_LOCK_MS = 1400
const NAV_IDS_THAT_RESET_SCROLL = new Set(['home', 'accounts'])

let scrollLockUntil = 0
let scrollLockFrame = 0

function forceDocumentTop() {
  const app = document.querySelector('.app')
  app?.scrollIntoView?.({ block: 'start', inline: 'nearest', behavior: 'auto' })
  window.scrollTo({ top: 0, left: 0, behavior: 'auto' })
  if (document.scrollingElement) document.scrollingElement.scrollTop = 0
  document.documentElement.scrollTop = 0
  if (document.body) document.body.scrollTop = 0
}

function scrollLockTick() {
  forceDocumentTop()
  if (performance.now() < scrollLockUntil) {
    scrollLockFrame = window.requestAnimationFrame(scrollLockTick)
  } else {
    scrollLockFrame = 0
  }
}

export function lockScreenToTop(duration = SCROLL_LOCK_MS) {
  scrollLockUntil = Math.max(scrollLockUntil, performance.now() + duration)
  forceDocumentTop()
  if (!scrollLockFrame) scrollLockFrame = window.requestAnimationFrame(scrollLockTick)
}

function hardenTelegramGestures() {
  const webApp = window.Telegram?.WebApp
  webApp?.disableVerticalSwipes?.()
}

if ('scrollRestoration' in window.history) window.history.scrollRestoration = 'manual'
hardenTelegramGestures()
lockScreenToTop()

window.addEventListener('pageshow', () => {
  hardenTelegramGestures()
  lockScreenToTop()
})

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState !== 'visible') return
  hardenTelegramGestures()
  lockScreenToTop()
})

document.addEventListener('click', (event) => {
  const navItem = event.target.closest?.('.labBottomNavItem[data-nav-id]')
  if (!navItem) return
  if (NAV_IDS_THAT_RESET_SCROLL.has(navItem.dataset.navId)) lockScreenToTop()
}, true)
