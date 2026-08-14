import { useEffect, useState } from 'react'
import {
  changeSecurityPin,
  disableSecurity,
  enrollBiometric,
  getSecurityStatus,
  revokeBiometric,
  setupSecurityPin,
} from './api.js'
import { clearUnlockSession, setUnlockSession } from './security-session.js'

function initBiometricManager() {
  return new Promise((resolve) => {
    const manager = window.Telegram?.WebApp?.BiometricManager
    if (!manager) return resolve(null)
    if (manager.isInited) return resolve(manager)
    manager.init(() => resolve(manager))
  })
}

function requestBiometricAccess(manager) {
  return new Promise((resolve) => {
    manager.requestAccess({ reason: 'Разблокировка MoneyTrack без ввода PIN' }, (granted) => resolve(granted === true))
  })
}

function updateBiometricToken(manager, token) {
  return new Promise((resolve) => manager.updateBiometricToken(token, (updated) => resolve(updated === true)))
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

const digits = (value) => value.replace(/\D/g, '').slice(0, 6)

export default function SecuritySettings() {
  const [status, setStatus] = useState(null)
  const [manager, setManager] = useState(null)
  const [pin, setPin] = useState('')
  const [pinAgain, setPinAgain] = useState('')
  const [currentPin, setCurrentPin] = useState('')
  const [newPin, setNewPin] = useState('')
  const [newPinAgain, setNewPinAgain] = useState('')
  const [disablePin, setDisablePin] = useState('')
  const [disableConfirmed, setDisableConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)

  const refresh = async (currentManager = manager) => {
    const next = await getSecurityStatus(currentManager?.deviceId || '')
    setStatus(next)
    return next
  }

  useEffect(() => {
    let active = true
    initBiometricManager()
      .then(async (current) => {
        if (!active) return
        setManager(current)
        const next = await getSecurityStatus(current?.deviceId || '')
        if (active) setStatus(next)
      })
      .catch((error) => active && showError(error?.message || 'Не удалось загрузить настройки защиты'))
    return () => { active = false }
  }, [])

  const enablePin = async () => {
    if (busy) return
    if (!/^\d{6}$/.test(pin)) return showError('PIN должен состоять ровно из 6 цифр.')
    if (pin !== pinAgain) return showError('PIN-коды не совпадают.')
    setBusy(true)
    try {
      const result = await setupSecurityPin(pin)
      setUnlockSession(result?.unlock_token, result?.expires_at)
      setPin('')
      setPinAgain('')
      await refresh()
      window.dispatchEvent(new CustomEvent('moneytrack:security-changed', {
        detail: { protection_enabled: true, expires_at: result?.expires_at || null },
      }))
    } catch (error) {
      showError(error?.message || 'Не удалось включить PIN.')
    } finally {
      setBusy(false)
    }
  }

  const changePin = async () => {
    if (busy) return
    if (!/^\d{6}$/.test(currentPin)) return showError('Введите текущий 6-значный PIN.')
    if (!/^\d{6}$/.test(newPin)) return showError('Новый PIN должен состоять ровно из 6 цифр.')
    if (newPin !== newPinAgain) return showError('Новые PIN-коды не совпадают.')
    setBusy(true)
    try {
      const result = await changeSecurityPin(currentPin, newPin, newPinAgain)
      setUnlockSession(result?.unlock_token, result?.expires_at)
      setCurrentPin('')
      setNewPin('')
      setNewPinAgain('')
      await refresh()
      window.dispatchEvent(new CustomEvent('moneytrack:security-changed', {
        detail: { protection_enabled: true, expires_at: result?.expires_at || null },
      }))
    } catch (error) {
      showError(error?.message || 'Не удалось изменить PIN.')
    } finally {
      setBusy(false)
    }
  }

  const disableApplicationLock = async () => {
    if (busy) return
    if (!disableConfirmed) return showError('Подтвердите отключение защиты.')
    if (!/^\d{6}$/.test(disablePin)) return showError('Введите текущий 6-значный PIN.')
    setBusy(true)
    try {
      await disableSecurity(disablePin, true)
      // Server revocation is authoritative. Current-device Telegram cleanup is best effort.
      if (manager?.isInited) {
        try { await updateBiometricToken(manager, '') } catch { /* best effort */ }
      }
      clearUnlockSession()
      setDisablePin('')
      setDisableConfirmed(false)
      setStatus((current) => ({ ...(current || {}), protection_enabled: false, pin_enabled: false, biometric_enrolled: false }))
      window.dispatchEvent(new CustomEvent('moneytrack:security-changed', {
        detail: {
          protection_enabled: false,
          biometric_enrolled: false,
          biometric_token_saved: false,
        },
      }))
    } catch (error) {
      showError(error?.message || 'Не удалось отключить защиту.')
    } finally {
      setBusy(false)
    }
  }

  const enableBiometric = async () => {
    if (!manager || busy || status?.pin_enabled !== true) return
    setBusy(true)
    let serverEnrolled = false
    try {
      let granted = manager.isAccessGranted === true

      if (
        !granted
        && manager.isAccessRequested === true
        && typeof manager.openSettings === 'function'
      ) {
        manager.openSettings()
        return
      }

      if (!granted) granted = await requestBiometricAccess(manager)

      if (!granted) {
        showError('Telegram не дал доступ к биометрии. Повторите действие, чтобы открыть настройки Telegram. PIN остаётся доступен.')
        return
      }
      const result = await enrollBiometric(manager.deviceId)
      serverEnrolled = true
      const stored = await updateBiometricToken(manager, result?.biometric_token || '')
      if (!stored) throw new Error('BIOMETRIC_TOKEN_STORE_FAILED')
      await refresh(manager)

      window.dispatchEvent(new CustomEvent('moneytrack:security-changed', {
        detail: {
          protection_enabled: true,
          biometric_enrolled: true,
          biometric_token_saved: true,
        },
      }))
    } catch (error) {
      if (serverEnrolled && manager?.deviceId) {
        try { await revokeBiometric(manager.deviceId) } catch { /* best effort rollback */ }
      }
      showError(error?.message || 'Не удалось включить биометрию.')
    } finally {
      setBusy(false)
    }
  }

  const disableBiometric = async () => {
    if (!manager || busy) return
    setBusy(true)
    try {
      // Fail closed: do not revoke the server credential until Telegram
      // confirms that the protected on-device token was removed.
      const removed = await updateBiometricToken(manager, '')
      if (!removed) throw new Error('BIOMETRIC_TOKEN_REMOVE_FAILED')

      await revokeBiometric(manager.deviceId)
      await refresh(manager)

      window.dispatchEvent(new CustomEvent('moneytrack:security-changed', {
        detail: {
          protection_enabled: true,
          biometric_enrolled: false,
          biometric_token_saved: false,
        },
      }))
    } catch (error) {
      showError(error?.message || 'Не удалось отключить биометрию.')
    } finally {
      setBusy(false)
    }
  }

  const biometricAvailable = Boolean(
    manager?.isInited
    && manager?.isBiometricAvailable
    && manager?.deviceId
  )

  const biometricServerEnrolled = status?.biometric_enrolled === true
  const biometricAccessGranted = manager?.isAccessGranted === true
  const biometricTokenSaved = manager?.isBiometricTokenSaved === true

  const biometricReady = Boolean(
    biometricServerEnrolled
    && biometricAccessGranted
    && biometricTokenSaved
  )

  const biometricNeedsRepair = Boolean(
    biometricServerEnrolled
    && !biometricReady
  )

  return (
    <section className="securitySettings" aria-label="Защита приложения">
      <div className="securitySettingsTitle">
        <strong>Защита приложения</strong>
        <span>{status?.pin_enabled ? 'PIN включён' : 'Защита выключена'}</span>
      </div>

      {status?.pin_enabled !== true && (
        <div className="securitySettingsPin">
          <input type="password" aria-label="Новый PIN" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="6 цифр" value={pin} onChange={(event) => setPin(digits(event.target.value))} disabled={busy} />
          <input type="password" aria-label="Повторите PIN" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="Повторите PIN" value={pinAgain} onChange={(event) => setPinAgain(digits(event.target.value))} disabled={busy} />
          <button type="button" onClick={enablePin} disabled={busy || pin.length !== 6 || pinAgain.length !== 6}>Включить PIN</button>
        </div>
      )}

      {status?.pin_enabled === true && (
        <div className="securitySettingsPin">
          <strong>Изменить PIN</strong>
          <input type="password" aria-label="Текущий PIN" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="Текущий PIN" value={currentPin} onChange={(event) => setCurrentPin(digits(event.target.value))} disabled={busy} />
          <input type="password" aria-label="Новый PIN" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="Новый PIN" value={newPin} onChange={(event) => setNewPin(digits(event.target.value))} disabled={busy} />
          <input type="password" aria-label="Повторите новый PIN" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="Повторите новый PIN" value={newPinAgain} onChange={(event) => setNewPinAgain(digits(event.target.value))} disabled={busy} />
          <button type="button" onClick={changePin} disabled={busy || currentPin.length !== 6 || newPin.length !== 6 || newPinAgain.length !== 6}>Изменить PIN</button>
        </div>
      )}

      {status?.pin_enabled === true && biometricAvailable && !biometricServerEnrolled && (
        <button type="button" onClick={enableBiometric} disabled={busy}>Включить биометрию</button>
      )}

      {status?.pin_enabled === true && biometricAvailable && biometricNeedsRepair && (
        <>
          <small>Биометрия зарегистрирована, но локальная защита Telegram требует восстановления.</small>
          <button type="button" onClick={enableBiometric} disabled={busy}>Восстановить биометрию</button>
        </>
      )}

      {status?.pin_enabled === true && biometricAvailable && biometricReady && (
        <button type="button" onClick={disableBiometric} disabled={busy}>Отключить биометрию на этом устройстве</button>
      )}
      {status?.pin_enabled === true && !biometricAvailable && (
        <small>На этом устройстве Telegram не предоставляет биометрическую разблокировку. PIN остаётся доступен.</small>
      )}

      {status?.pin_enabled === true && (
        <div className="securitySettingsPin">
          <strong>Отключить защиту приложения</strong>
          <input type="password" aria-label="PIN для отключения защиты" inputMode="numeric" autoComplete="off" maxLength={6} placeholder="Текущий PIN" value={disablePin} onChange={(event) => setDisablePin(digits(event.target.value))} disabled={busy} />
          <label>
            <input type="checkbox" checked={disableConfirmed} onChange={(event) => setDisableConfirmed(event.target.checked)} disabled={busy} />
            Подтверждаю отключение PIN и биометрии на всех устройствах
          </label>
          <button type="button" onClick={disableApplicationLock} disabled={busy || disablePin.length !== 6 || !disableConfirmed}>Отключить защиту</button>
        </div>
      )}
    </section>
  )
}
