import { Children, useCallback, useEffect, useMemo, useState } from 'react'
import {
  acceptSpaceInvite,
  createSpace,
  createSpaceInvite,
  getSpaceMembers,
  getSpaces,
  removeSpaceMember,
  revokeSpaceInvite,
  setActiveSpace as persistActiveSpace,
  setDefaultCaptureSpace,
} from './api.js'
import { clearActiveSpaceId, setActiveSpaceId, SpaceContext } from './space-context.js'

let inviteAcceptanceParam = ''
let inviteAcceptancePromise = null

function normalizeSpaces(payload) {
  const raw = payload?.spaces ?? payload?.items ?? payload?.data?.spaces ?? []
  return Array.isArray(raw) ? raw.map((item) => ({
    ...item,
    id: Number(item.id ?? item.space_id),
    name: String(item.name ?? item.space_name ?? 'Space'),
  })).filter((item) => Number.isSafeInteger(item.id) && item.id > 0) : []
}

function currentId(payload) {
  const value = payload?.current_space_id
    ?? payload?.current_workspace_id
    ?? payload?.active_space_id
    ?? payload?.data?.current_space_id
  const numeric = Number(value)
  return Number.isSafeInteger(numeric) && numeric > 0 ? numeric : null
}

function defaultCaptureId(payload) {
  const value = payload?.default_capture_space_id ?? payload?.data?.default_capture_space_id
  const numeric = Number(value)
  return Number.isSafeInteger(numeric) && numeric > 0 ? numeric : null
}

function resultSpaceId(payload) {
  const value = payload?.space_id ?? payload?.id ?? payload?.space?.id ?? payload?.data?.space_id
  const numeric = Number(value)
  return Number.isSafeInteger(numeric) && numeric > 0 ? numeric : null
}

function telegramInviteStartParam() {
  const raw = String(window.Telegram?.WebApp?.initDataUnsafe?.start_param || '').trim()
  return raw.startsWith('invite_') ? raw : ''
}

function acceptTelegramInviteOnce() {
  const startParam = telegramInviteStartParam()
  if (!startParam) return Promise.resolve(null)

  if (inviteAcceptancePromise && inviteAcceptanceParam === startParam) {
    return inviteAcceptancePromise
  }

  inviteAcceptanceParam = startParam
  inviteAcceptancePromise = acceptSpaceInvite(startParam)
    .then((result) => resultSpaceId(result))
    .catch((error) => {
      inviteAcceptanceParam = ''
      inviteAcceptancePromise = null
      throw error
    })

  return inviteAcceptancePromise
}

function normalizeMembers(payload) {
  const raw = payload?.members ?? payload?.data?.members ?? []
  return Array.isArray(raw) ? raw.map((item) => ({
    ...item,
    user_id: Number(item.user_id),
    role: String(item.role || 'member'),
    is_active: item.is_active !== false,
  })).filter((item) => Number.isSafeInteger(item.user_id) && item.user_id > 0) : []
}

export default function SpaceGate({ children }) {
  const [spaces, setSpaces] = useState([])
  const [activeSpace, setActiveSpace] = useState(null)
  const [defaultCaptureSpaceId, setDefaultCaptureSpaceIdState] = useState(null)
  const [switching, setSwitching] = useState(true)
  const [error, setError] = useState('')
  const [creating, setCreating] = useState(false)
  const [newSpaceName, setNewSpaceName] = useState('')
  const [managementOpen, setManagementOpen] = useState(false)
  const [managementLoading, setManagementLoading] = useState(false)
  const [managementError, setManagementError] = useState('')
  const [members, setMembers] = useState([])
  const [invite, setInvite] = useState(null)
  const [inviteBusy, setInviteBusy] = useState(false)

  const loadSpaces = useCallback(async ({ preserveActive = false } = {}) => {
    const payload = await getSpaces()
    const nextSpaces = normalizeSpaces(payload)
    if (!nextSpaces.length) throw new Error('Нет доступного финансового пространства')

    const preferred = preserveActive && activeSpace
      ? nextSpaces.find((space) => space.id === activeSpace.id)
      : nextSpaces.find((space) => space.id === currentId(payload))
    const next = preferred ?? nextSpaces[0]

    setSpaces(nextSpaces)
    setDefaultCaptureSpaceIdState(defaultCaptureId(payload))
    setActiveSpaceId(next.id)
    setActiveSpace(next)
    return next
  }, [activeSpace])

  useEffect(() => {
    let cancelled = false
    clearActiveSpaceId()

    const initializeSpace = async () => {
      let invitedSpaceId = null
      let inviteError = ''

      try {
        invitedSpaceId = await acceptTelegramInviteOnce()
      } catch (reason) {
        inviteError = reason?.message || 'Не удалось принять приглашение в пространство'
      }

      if (cancelled) return

      const payload = await getSpaces()
      if (cancelled) return

      const nextSpaces = normalizeSpaces(payload)
      if (!nextSpaces.length) throw new Error('Нет доступного финансового пространства')

      const next = nextSpaces.find((space) => space.id === invitedSpaceId)
        ?? nextSpaces.find((space) => space.id === currentId(payload))
        ?? nextSpaces[0]

      if (currentId(payload) !== next.id) {
        await persistActiveSpace(next.id)
        if (cancelled) return
      }

      setSpaces(nextSpaces)
      setDefaultCaptureSpaceIdState(defaultCaptureId(payload))
      setActiveSpaceId(next.id)
      setActiveSpace(next)
      if (inviteError) setError(inviteError)
    }

    initializeSpace()
      .catch((reason) => {
        if (!cancelled) setError(reason?.message || 'Не удалось загрузить пространства')
      })
      .finally(() => {
        if (!cancelled) setSwitching(false)
      })

    return () => {
      cancelled = true
      clearActiveSpaceId()
    }
  }, [])

  const switchSpace = useCallback(async (spaceId, availableSpaces = spaces) => {
    const targetId = Number(spaceId)
    const target = availableSpaces.find((space) => space.id === targetId)
    if (!target || target.id === activeSpace?.id || switching) return

    const previous = activeSpace
    setError('')
    setSwitching(true)
    setManagementOpen(false)
    setMembers([])
    setInvite(null)

    // Security/UX invariant: old Space financial state is destroyed before the
    // request that selects/loads the new Space. No stale values can flash.
    clearActiveSpaceId()
    setActiveSpace(null)

    try {
      await persistActiveSpace(target.id)
      setActiveSpaceId(target.id)
      setActiveSpace(target)
    } catch (reason) {
      if (previous) {
        setActiveSpaceId(previous.id)
        setActiveSpace(previous)
      }
      setError(reason?.message || 'Не удалось переключить пространство')
      throw reason
    } finally {
      setSwitching(false)
    }
  }, [activeSpace, spaces, switching])

  const reloadSpaces = useCallback(async () => {
    setError('')
    return loadSpaces({ preserveActive: true })
  }, [loadSpaces])

  const submitCreate = async (event) => {
    event.preventDefault()
    const name = newSpaceName.trim()
    if (!name) return
    setCreating(true)
    setError('')
    try {
      const created = await createSpace(name)
      setNewSpaceName('')
      const payload = await getSpaces()
      const nextSpaces = normalizeSpaces(payload)
      setSpaces(nextSpaces)
      setDefaultCaptureSpaceIdState(defaultCaptureId(payload))
      const createdId = Number(created?.space_id ?? created?.id ?? created?.space?.id)
      if (Number.isSafeInteger(createdId) && nextSpaces.some((space) => space.id === createdId)) {
        await switchSpace(createdId, nextSpaces)
      }
    } catch (reason) {
      setError(reason?.message || 'Не удалось создать пространство')
    } finally {
      setCreating(false)
    }
  }

  const refreshMembers = useCallback(async (space = activeSpace) => {
    if (!space?.is_owner) {
      setMembers([])
      return []
    }
    setManagementLoading(true)
    setManagementError('')
    try {
      const payload = await getSpaceMembers(space.id)
      const nextMembers = normalizeMembers(payload)
      setMembers(nextMembers)
      return nextMembers
    } catch (reason) {
      setManagementError(reason?.message || 'Не удалось загрузить участников')
      throw reason
    } finally {
      setManagementLoading(false)
    }
  }, [activeSpace])

  const openManagement = () => {
    setManagementOpen(true)
    setManagementError('')
    setInvite(null)
    if (activeSpace?.is_owner) refreshMembers(activeSpace).catch(() => {})
  }

  const makeDefaultCapture = async () => {
    if (!activeSpace || defaultCaptureSpaceId === activeSpace.id) return
    setManagementLoading(true)
    setManagementError('')
    try {
      await setDefaultCaptureSpace(activeSpace.id)
      setDefaultCaptureSpaceIdState(activeSpace.id)
    } catch (reason) {
      setManagementError(reason?.message || 'Не удалось выбрать пространство для бота')
    } finally {
      setManagementLoading(false)
    }
  }

  const createInvite = async () => {
    if (!activeSpace?.is_owner || inviteBusy) return
    setInviteBusy(true)
    setManagementError('')
    try {
      const created = await createSpaceInvite(activeSpace.id)
      const inviteUrl = String(created?.invite_url || '')
      const inviteId = Number(created?.invite_id)
      if (!inviteUrl || !Number.isSafeInteger(inviteId)) throw new Error('Сервис не вернул ссылку приглашения')
      setInvite({
        id: inviteId,
        url: inviteUrl,
        expiresAt: created?.expires_at || null,
        revoked: false,
      })
    } catch (reason) {
      setManagementError(reason?.message || 'Не удалось создать приглашение')
    } finally {
      setInviteBusy(false)
    }
  }

  const copyInvite = async () => {
    if (!invite?.url) return
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(invite.url)
        window.Telegram?.WebApp?.showAlert?.('Ссылка приглашения скопирована')
      } else {
        window.prompt('Скопируйте ссылку приглашения', invite.url)
      }
    } catch {
      window.prompt('Скопируйте ссылку приглашения', invite.url)
    }
  }

  const shareInvite = () => {
    if (!invite?.url) return
    const shareUrl = `https://t.me/share/url?url=${encodeURIComponent(invite.url)}`
    if (window.Telegram?.WebApp?.openTelegramLink) window.Telegram.WebApp.openTelegramLink(shareUrl)
    else window.open(shareUrl, '_blank', 'noopener,noreferrer')
  }

  const revokeInvite = async () => {
    if (!invite?.id || invite.revoked || inviteBusy) return
    setInviteBusy(true)
    setManagementError('')
    try {
      await revokeSpaceInvite(invite.id)
      setInvite((current) => current ? { ...current, revoked: true } : current)
    } catch (reason) {
      setManagementError(reason?.message || 'Не удалось отозвать приглашение')
    } finally {
      setInviteBusy(false)
    }
  }

  const removeMember = async (member) => {
    if (!activeSpace?.is_owner || member?.role === 'owner' || !member?.is_active) return
    const confirmed = window.confirm(`Удалить пользователя #${member.user_id} из «${activeSpace.name}»?`)
    if (!confirmed) return
    setManagementLoading(true)
    setManagementError('')
    try {
      await removeSpaceMember(activeSpace.id, member.user_id)
      await refreshMembers(activeSpace)
      await reloadSpaces()
    } catch (reason) {
      setManagementError(reason?.message || 'Не удалось удалить участника')
    } finally {
      setManagementLoading(false)
    }
  }

  const value = useMemo(() => ({
    activeSpace,
    spaces,
    switching,
    switchSpace,
    reloadSpaces,
  }), [activeSpace, spaces, switching, switchSpace, reloadSpaces])

  if (switching && !activeSpace) {
    return <main className="app loadingState spaceGateLoading" aria-busy="true"><div className="skeleton topSkeleton"/><div className="skeleton heroSkeleton"/></main>
  }

  if (!activeSpace) {
    return <main className="app"><div className="notice" role="alert">{error || 'Финансовое пространство недоступно'}</div></main>
  }

  return (
    <SpaceContext.Provider value={value}>
      <div className="spaceGate" data-space-id={activeSpace.id}>
        <header className="spaceBar" aria-label="Текущее финансовое пространство">
          <label className="spaceBarIdentity">
            <span>Пространство</span>
            <select
              value={activeSpace.id}
              onChange={(event) => switchSpace(event.target.value).catch(() => {})}
              disabled={switching}
              aria-label="Текущее пространство"
            >
              {spaces.map((space) => <option key={space.id} value={space.id}>{space.name}</option>)}
            </select>
          </label>
          <form className="spaceCreateInline" onSubmit={submitCreate}>
            <input
              value={newSpaceName}
              onChange={(event) => setNewSpaceName(event.target.value)}
              placeholder="Новое пространство"
              maxLength={120}
              aria-label="Название нового пространства"
            />
            <button type="submit" disabled={creating || !newSpaceName.trim()} aria-label="Создать пространство">+</button>
          </form>
          <button type="button" className="spaceManageButton" onClick={openManagement} aria-label="Управление пространством">⋯</button>
        </header>
        {error && <div className="notice spaceGateNotice" role="alert">{error}</div>}
        <div className="spaceFinancialRoot" key={activeSpace.id}>
          {Children.toArray(children)}
        </div>

        {managementOpen && (
          <div className="spaceManageBackdrop" role="presentation" onClick={(event) => {
            if (event.target === event.currentTarget) setManagementOpen(false)
          }}>
            <section className="spaceManageSheet" role="dialog" aria-modal="true" aria-label="Управление пространством">
              <header className="spaceManageHeader">
                <div>
                  <span>Пространство</span>
                  <strong>{activeSpace.name}</strong>
                </div>
                <button type="button" onClick={() => setManagementOpen(false)} aria-label="Закрыть">×</button>
              </header>

              <div className="spaceManageSummary">
                <span>{activeSpace.is_owner ? 'Владелец' : 'Участник'}</span>
                <span>{Number(activeSpace.member_count || 1)} участник(а)</span>
              </div>

              <button
                type="button"
                className="spaceDefaultCaptureButton"
                onClick={makeDefaultCapture}
                disabled={managementLoading || defaultCaptureSpaceId === activeSpace.id}
              >
                {defaultCaptureSpaceId === activeSpace.id ? '✓ Пространство для бота' : 'Использовать для бота'}
              </button>
              <p className="spaceManageHint">Bot capture использует это назначение независимо от последнего выбранного пространства MiniApp.</p>

              {activeSpace.is_owner && (
                <>
                  <section className="spaceManageSection">
                    <div className="spaceManageSectionHead">
                      <div><span>Совместный доступ</span><strong>Приглашение</strong></div>
                      <button type="button" onClick={createInvite} disabled={inviteBusy}>{inviteBusy ? '…' : 'Создать ссылку'}</button>
                    </div>
                    {invite && (
                      <div className="spaceInviteCard" data-revoked={invite.revoked ? 'true' : 'false'}>
                        <input readOnly value={invite.url} aria-label="Ссылка приглашения" />
                        {invite.expiresAt && <small>Действует до {new Date(invite.expiresAt).toLocaleString()}</small>}
                        {invite.revoked ? (
                          <strong className="spaceInviteRevoked">Приглашение отозвано</strong>
                        ) : (
                          <div className="spaceInviteActions">
                            <button type="button" onClick={copyInvite}>Копировать</button>
                            <button type="button" onClick={shareInvite}>Отправить</button>
                            <button type="button" onClick={revokeInvite} disabled={inviteBusy}>Отозвать</button>
                          </div>
                        )}
                      </div>
                    )}
                  </section>

                  <section className="spaceManageSection">
                    <div className="spaceManageSectionHead">
                      <div><span>Совместный доступ</span><strong>Участники</strong></div>
                      <button type="button" onClick={() => refreshMembers(activeSpace).catch(() => {})} disabled={managementLoading}>Обновить</button>
                    </div>
                    {managementLoading && !members.length && <div className="spaceMemberEmpty">Загрузка…</div>}
                    {!managementLoading && !members.length && <div className="spaceMemberEmpty">Участников пока нет</div>}
                    <div className="spaceMemberList">
                      {members.map((member) => (
                        <div className="spaceMemberRow" key={member.user_id}>
                          <div>
                            <strong>Пользователь #{member.user_id}</strong>
                            <small>{member.role === 'owner' ? 'Владелец' : member.is_active ? 'Участник' : 'Доступ отозван'}</small>
                          </div>
                          {member.role !== 'owner' && member.is_active && (
                            <button type="button" onClick={() => removeMember(member)} disabled={managementLoading}>Удалить</button>
                          )}
                        </div>
                      ))}
                    </div>
                  </section>
                </>
              )}

              {managementError && <div className="notice spaceManageError" role="alert">{managementError}</div>}
            </section>
          </div>
        )}
      </div>
    </SpaceContext.Provider>
  )
}
