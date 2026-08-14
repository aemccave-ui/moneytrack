function applyTelegramGesturePolicy() {
  try {
    window.Telegram?.WebApp?.disableVerticalSwipes?.()
  } catch {
    // Telegram API is optional outside the MiniApp runtime.
  }
}

applyTelegramGesturePolicy()
window.addEventListener('load', applyTelegramGesturePolicy, { once: true })
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) applyTelegramGesturePolicy()
})
