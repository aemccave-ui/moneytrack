import { useEffect, useRef, useState } from 'react'
import { announceSwipeOpen, nextSwipeScope, SWIPE_OPEN_EVENT } from './swipe-coordinator.js'

export function SwipeReveal({
  id,
  actions,
  children,
  actionWidth = 56,
  autoCloseMs = 2000,
  disabled = false,
  className = '',
}) {
  const width = Math.max(actionWidth, actions.length * actionWidth)
  const [dragX, setDragX] = useState(0)
  const [open, setOpen] = useState(false)
  const [dragging, setDragging] = useState(false)
  const [scope] = useState(() => nextSwipeScope('reveal'))
  const startRef = useRef(null)
  const timerRef = useRef(null)
  const movedRef = useRef(false)
  const key = `${scope}:${id}`
  const restingX = open ? -width : 0
  const effectiveX = dragging ? dragX : restingX

  const clearTimer = () => {
    if (timerRef.current != null) window.clearTimeout(timerRef.current)
    timerRef.current = null
  }

  const closeActions = () => {
    clearTimer()
    setOpen(false)
    setDragX(0)
  }

  const scheduleClose = () => {
    clearTimer()
    timerRef.current = window.setTimeout(() => {
      setOpen(false)
      setDragX(0)
      timerRef.current = null
    }, autoCloseMs)
  }

  const openActions = () => {
    if (!actions.length) {
      closeActions()
      return
    }
    announceSwipeOpen(key)
    setOpen(true)
    setDragX(-width)
    scheduleClose()
  }

  useEffect(() => {
    const onOtherSwipe = (event) => {
      if (event.detail?.key === key) return
      if (timerRef.current != null) window.clearTimeout(timerRef.current)
      timerRef.current = null
      setOpen(false)
      setDragX(0)
    }
    window.addEventListener(SWIPE_OPEN_EVENT, onOtherSwipe)
    return () => {
      if (timerRef.current != null) window.clearTimeout(timerRef.current)
      timerRef.current = null
      window.removeEventListener(SWIPE_OPEN_EVENT, onOtherSwipe)
    }
  }, [key])

  const onPointerDown = (event) => {
    if (disabled || event.button > 0) return
    if (event.target.closest('button[data-swipe-action]')) return
    clearTimer()
    movedRef.current = false
    startRef.current = { x: event.clientX, y: event.clientY, baseX: restingX }
    setDragX(restingX)
    setDragging(false)
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  const onPointerMove = (event) => {
    if (!startRef.current || disabled) return
    const dx = event.clientX - startRef.current.x
    const dy = event.clientY - startRef.current.y
    if (!dragging) {
      if (Math.abs(dx) < 7 || Math.abs(dx) <= Math.abs(dy)) return
      setDragging(true)
      movedRef.current = true
    }
    event.preventDefault()
    const next = startRef.current.baseX + dx
    setDragX(Math.max(-width, Math.min(0, next)))
  }

  const settle = () => {
    if (!startRef.current || disabled) return
    const finalX = dragX
    startRef.current = null
    if (finalX <= -(width * .34)) openActions()
    else closeActions()
    window.setTimeout(() => setDragging(false), 0)
  }

  const cancel = () => {
    startRef.current = null
    setDragging(false)
    closeActions()
  }

  return (
    <div className={`swipeReveal ${open ? 'isOpen' : ''} ${className}`.trim()}>
      <div
        className="swipeRevealActions"
        style={{
          width: `${width}px`,
          gridTemplateColumns: `repeat(${Math.max(actions.length, 1)}, minmax(0, 1fr))`,
        }}
        aria-hidden={!open && !dragging}
      >
        {actions.map((action) => (
          <button
            key={action.key}
            type="button"
            data-swipe-action
            className={`swipeActionButton ${action.danger ? 'danger' : ''}`.trim()}
            disabled={disabled || action.disabled}
            onClick={(event) => {
              event.preventDefault()
              event.stopPropagation()
              closeActions()
              action.onClick?.()
            }}
          >
            {action.icon}
            <span>{action.label}</span>
          </button>
        ))}
      </div>
      <div
        className={`swipeRevealSurface ${dragging ? 'isDragging' : ''}`}
        style={effectiveX ? { transform: `translate3d(${effectiveX}px,0,0)` } : undefined}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={settle}
        onPointerCancel={cancel}
        onClickCapture={(event) => {
          if (movedRef.current || open) {
            if (open) closeActions()
            if (movedRef.current) event.stopPropagation()
          }
          movedRef.current = false
        }}
      >
        {children({ open })}
      </div>
    </div>
  )
}
