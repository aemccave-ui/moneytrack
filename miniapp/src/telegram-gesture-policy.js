function applyTelegramGesturePolicy() {
  try {
    window.Telegram?.WebApp?.disableVerticalSwipes?.()
  } catch {
    // Telegram API is optional outside the MiniApp runtime.
  }
}

applyTelegramGesturePolicy()
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) applyTelegramGesturePolicy()
})
