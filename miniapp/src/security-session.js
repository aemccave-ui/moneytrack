let unlockToken = ''
let unlockExpiresAt = 0

export function setUnlockSession(token, expiresAt = null) {
  unlockToken = String(token || '')
  const parsed = expiresAt ? new Date(expiresAt).getTime() : 0
  unlockExpiresAt = Number.isFinite(parsed) ? parsed : 0
}

export function getUnlockToken() {
  if (!unlockToken) return ''
  if (unlockExpiresAt && Date.now() >= unlockExpiresAt) {
    clearUnlockSession()
    return ''
  }
  return unlockToken
}

export function clearUnlockSession() {
  unlockToken = ''
  unlockExpiresAt = 0
}

export function unlockSessionExpiresAt() {
  return unlockExpiresAt || null
}
