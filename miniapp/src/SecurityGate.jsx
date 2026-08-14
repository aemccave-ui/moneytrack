import { useCallback, useEffect, useRef, useState } from 'react'
import { getSecurityStatus, unlockWithBiometric, unlockWithPin } from './api.js'
import { clearUnlockSession, setUnlockSession } from './security-session.js'
import './security.css'

const BACKGROUND_RELOCK_MS = 60_000

function messageFor(error) {
  const code = String(error?.code || error?.message || '')
  if (code.includes('PIN_LOCKED')) return 'Слишком много попыток. PIN временно заблокирован.'
  if (code.includes('PIN_INVALID')) return 'Неверный PIN.'
  if (code.includes('BIOMETRIC')) return 'Биометрическая проверка не выполнена. Используйте PIN.'
  if (code.includes('INIT_DATA')) return 'Не удалось подтвердить вход через Telegram. Откройте MoneyTrack заново.'
  return error?.message || 'Не удалось разблокировать MoneyTrack.'
}

function initBiometricManager() {
  return new Promise((resolve) => {
    const manager = window.Telegram?.WebApp?.BiometricManager
    if (!manager) {
      resolve(null)
      return
    }
    if (manager.isInited) {
      resolve(manager)
      return
    }
    manager.init(() => resolve(manager))
  })
}

function authenticateBiometric(manager) {
  return new Promise((resolve) => {
    manager.authenticate({ reason: 'Разблокировать MoneyTrack' }, (ok, token) => {
      resolve(ok ? String(token || '') : '')
    })
  })
}

export default function SecurityGate({ children }) {
  const [mode, setMode] = useState('loading')
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [protectionEnabled, setProtectionEnabled] = useState(false)
  const [biometric, setBiometric] = useState({
    manager: null,
    enrolled: false,
    tokenSaved: false,
  })
  const [sessionExpiresAt, setSessionExpiresAt] = useState(0)
  const hiddenAt = useRef(0)

  const lockNow = useCallback(() => {
    clearUnlockSession()
    setSessionExpiresAt(0)
    setPin('')
    setError('')
    setMode('locked')
  }, [])

  const bootstrap = useCallback(async () => {
    setMode('loading')
    setError('')
    try {
      const manager = await initBiometricManager()
      const status = await getSecurityStatus(manager?.deviceId || '')
      const enabled = status?.protection_enabled === true
      setProtectionEnabled(enabled)
      setBiometric({
        manager,
        enrolled: status?.biometric_enrolled === true,
        tokenSaved: manager?.isBiometricTokenSaved === true,
      })
      if (enabled) {
        clearUnlockSession()
        setMode('locked')
      } else {
        setMode('open')
      }
    } catch (bootstrapError) {
      clearUnlockSession()
      setError(messageFor(bootstrapError))
      setMode('error')
    }
  }, [])

  useEffect(() => {
    const bootstrapTimer = window.setTimeout(() => {
      void bootstrap()
    }, 0)

    return () => {
      window.clearTimeout(bootstrapTimer)
    }
  }, [bootstrap])

  useEffect(() => {
    const manager = biometric.manager
    const webApp = window.Telegram?.WebApp

    if (!manager || !webApp?.onEvent || !webApp?.offEvent) {
      return undefined
    }

    const syncBiometricManager = () => {
      setBiometric((current) => ({
        ...current,
        manager,
        tokenSaved: manager.isBiometricTokenSaved === true,
      }))
    }

    webApp.onEvent('biometricManagerUpdated', syncBiometricManager)

    return () => {
      webApp.offEvent('biometricManagerUpdated', syncBiometricManager)
    }
  }, [biometric.manager])

  useEffect(() => {
    const onLocked = () => {
      if (protectionEnabled) lockNow()
    }
    const onSecurityChanged = (event) => {
      const detail = event?.detail || {}

      if (typeof detail.protection_enabled === 'boolean') {
        const enabled = detail.protection_enabled
        setProtectionEnabled(enabled)

        if (!enabled) {
          clearUnlockSession()
          setSessionExpiresAt(0)
          setBiometric((current) => ({
            ...current,
            enrolled: false,
            tokenSaved: false,
          }))
          setMode('open')
        }
      }

      if (
        typeof detail.biometric_enrolled === 'boolean'
        || typeof detail.biometric_token_saved === 'boolean'
      ) {
        setBiometric((current) => ({
          ...current,
          enrolled: typeof detail.biometric_enrolled === 'boolean'
            ? detail.biometric_enrolled
            : current.enrolled,
          tokenSaved: typeof detail.biometric_token_saved === 'boolean'
            ? detail.biometric_token_saved
            : current.tokenSaved,
        }))
      }

      if (detail.expires_at) {
        const expires = new Date(detail.expires_at).getTime()
        setSessionExpiresAt(Number.isFinite(expires) ? expires : 0)
      }
    }
    window.addEventListener('moneytrack:locked', onLocked)
    window.addEventListener('moneytrack:security-changed', onSecurityChanged)
    return () => {
      window.removeEventListener('moneytrack:locked', onLocked)
      window.removeEventListener('moneytrack:security-changed', onSecurityChanged)
    }
  }, [lockNow, protectionEnabled])

  useEffect(() => {
    if (!protectionEnabled) return undefined

    const onVisibility = () => {
      if (document.hidden) {
        hiddenAt.current = Date.now()
        return
      }
      if (hiddenAt.current && Date.now() - hiddenAt.current > BACKGROUND_RELOCK_MS) lockNow()
      hiddenAt.current = 0
    }
    const onPageHide = () => clearUnlockSession()

    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('pagehide', onPageHide)
    return () => {
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('pagehide', onPageHide)
    }
  }, [lockNow, protectionEnabled])

  useEffect(() => {
    if (!protectionEnabled || mode !== 'open' || !sessionExpiresAt) return undefined
    const delay = Math.max(0, sessionExpiresAt - Date.now())
    const timer = window.setTimeout(lockNow, delay)
    return () => window.clearTimeout(timer)
  }, [lockNow, mode, protectionEnabled, sessionExpiresAt])

  const submitPin = async (event) => {
    event.preventDefault()
    if (!/^\d{6}$/.test(pin) || busy) return
    setBusy(true)
    setError('')
    try {
      const result = await unlockWithPin(pin)
      setUnlockSession(result?.unlock_token, result?.expires_at)
      const expires = result?.expires_at ? new Date(result.expires_at).getTime() : 0
      setSessionExpiresAt(Number.isFinite(expires) ? expires : 0)
      setPin('')
      setMode('open')
    } catch (unlockError) {
      setPin('')
      setError(messageFor(unlockError))
    } finally {
      setBusy(false)
    }
  }

  const useBiometric = async () => {
    const manager = biometric.manager
    if (!manager || busy) return
    setBusy(true)
    setError('')
    try {
      const token = await authenticateBiometric(manager)
      if (!token) throw new Error('BIOMETRIC_CANCELLED')
      const result = await unlockWithBiometric({ deviceId: manager.deviceId, biometricToken: token })
      setUnlockSession(result?.unlock_token, result?.expires_at)
      const expires = result?.expires_at ? new Date(result.expires_at).getTime() : 0
      setSessionExpiresAt(Number.isFinite(expires) ? expires : 0)
      setMode('open')
    } catch (biometricError) {
      setError(messageFor(biometricError))
    } finally {
      setBusy(false)
    }
  }

  if (mode === 'open') return children

  if (mode === 'loading') {
    return <main className="securityGate"><div className="securityCard" role="status">Проверка защиты…</div></main>
  }

  if (mode === 'error') {
    return (
      <main className="securityGate">
        <div className="securityCard">
          <h1>MoneyTrack</h1>
          <p className="securityError">{error}</p>
          <button type="button" onClick={bootstrap}>Повторить</button>
        </div>
      </main>
    )
  }

  const biometricReady = Boolean(
    biometric.enrolled
    && biometric.manager?.isInited
    && biometric.manager?.isBiometricAvailable
    && biometric.manager?.isAccessGranted
    && biometric.tokenSaved
    && biometric.manager?.deviceId
  )

  return (
    <main className="securityGate">
      <section className="securityCard" aria-label="Разблокировка MoneyTrack">
        <div className="securityLockMark" aria-hidden="true">●</div>
        <h1>MoneyTrack</h1>
        <p>Введите 6-значный PIN.</p>
        <form onSubmit={submitPin} className="securityPinForm">
          <input
            type="password"
            value={pin}
            onChange={(event) => setPin(event.target.value.replace(/\D/g, '').slice(0, 6))}
            inputMode="numeric"
            autoComplete="off"
            maxLength={6}
            pattern="[0-9]{6}"
            aria-label="PIN MoneyTrack"
            disabled={busy}
            autoFocus
          />
          <button type="submit" disabled={busy || pin.length !== 6}>{busy ? 'Проверка…' : 'Разблокировать'}</button>
        </form>
        {biometricReady && (
          <button type="button" className="securitySecondary" onClick={useBiometric} disabled={busy}>
            Использовать биометрию
          </button>
        )}
        {error && <p className="securityError" role="alert">{error}</p>}
      </section>
    </main>
  )
}
