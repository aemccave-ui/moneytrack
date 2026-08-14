import { Children, useCallback, useEffect, useMemo, useState } from 'react'
import { createSpace, getSpaces, setActiveSpace as persistActiveSpace } from './api.js'
import { clearActiveSpaceId, setActiveSpaceId, SpaceContext } from './space-context.js'

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

export default function SpaceGate({ children }) {
  const [spaces, setSpaces] = useState([])
  const [activeSpace, setActiveSpace] = useState(null)
  const [switching, setSwitching] = useState(true)
  const [error, setError] = useState('')
  const [creating, setCreating] = useState(false)
  const [newSpaceName, setNewSpaceName] = useState('')

  const loadSpaces = useCallback(async ({ preserveActive = false } = {}) => {
    const payload = await getSpaces()
    const nextSpaces = normalizeSpaces(payload)
    if (!nextSpaces.length) throw new Error('Нет доступного финансового пространства')

    const preferred = preserveActive && activeSpace
      ? nextSpaces.find((space) => space.id === activeSpace.id)
      : nextSpaces.find((space) => space.id === currentId(payload))
    const next = preferred ?? nextSpaces[0]

    setSpaces(nextSpaces)
    setActiveSpaceId(next.id)
    setActiveSpace(next)
    return next
  }, [activeSpace])

  useEffect(() => {
    let cancelled = false
    clearActiveSpaceId()
    setSwitching(true)
    getSpaces()
      .then(async (payload) => {
        if (cancelled) return
        const nextSpaces = normalizeSpaces(payload)
        if (!nextSpaces.length) throw new Error('Нет доступного финансового пространства')
        let next = nextSpaces.find((space) => space.id === currentId(payload)) ?? nextSpaces[0]
        if (currentId(payload) !== next.id) {
          await persistActiveSpace(next.id)
          if (cancelled) return
        }
        setSpaces(nextSpaces)
        setActiveSpaceId(next.id)
        setActiveSpace(next)
      })
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

  const switchSpace = useCallback(async (spaceId) => {
    const targetId = Number(spaceId)
    const target = spaces.find((space) => space.id === targetId)
    if (!target || target.id === activeSpace?.id || switching) return

    const previous = activeSpace
    setError('')
    setSwitching(true)

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
      const createdId = Number(created?.space_id ?? created?.id ?? created?.space?.id)
      if (Number.isSafeInteger(createdId) && nextSpaces.some((space) => space.id === createdId)) {
        await switchSpace(createdId)
      }
    } catch (reason) {
      setError(reason?.message || 'Не удалось создать пространство')
    } finally {
      setCreating(false)
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
        </header>
        {error && <div className="notice spaceGateNotice" role="alert">{error}</div>}
        <div className="spaceFinancialRoot" key={activeSpace.id}>
          {Children.toArray(children)}
        </div>
      </div>
    </SpaceContext.Provider>
  )
}
