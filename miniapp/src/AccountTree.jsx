import { useEffect, useRef, useState } from 'react'

const accountId = (account) => String(account.id ?? account.account_id)
const accountParentId = (account) => account.parent_account_id
  ?? account.parent_id
  ?? account.account_parent_id
  ?? account.parentAccountId
  ?? account.parentId
  ?? null

function subtreeIds(node) {
  return [accountId(node.account), ...node.children.flatMap(subtreeIds)]
}

function selectionState(node, selectedIds) {
  if (!selectedIds) return 'none'
  const ids = subtreeIds(node)
  const selected = ids.filter((id) => selectedIds.has(id)).length
  if (selected === 0) return 'none'
  if (selected === ids.length) return 'all'
  return 'partial'
}

function SwipeActionIcon({ name }) {
  if (name === 'edit') return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20h4l11-11-4-4L4 16v4ZM13.5 6.5l4 4" /></svg>
  if (name === 'archive') return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16v13H4V7Zm-1-3h18v3H3V4Zm6 7h6" /></svg>
  return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7h14M9 7V4h6v3M8 10v7M12 10v7M16 10v7M6 7l1 13h10l1-13" /></svg>
}

function TreeRow({
  node,
  depth,
  expanded,
  baseCurrency,
  privacy,
  money,
  selectedIds,
  onToggleParent,
  onToggleSelection,
  onNodeBody,
  isNodeBodyInteractive,
  resolveNodeAmount,
  onEdit,
  onArchive,
  onDelete,
  renderAfterNode,
  renderChildren,
  dragEnabled,
  dragging,
  dropTarget,
  onLongPressStart,
  onLongPressMove,
  onLongPressEnd,
}) {
  const id = accountId(node.account)
  const hasChildren = node.children.length > 0
  const isExpanded = expanded.has(id)
  const state = selectionState(node, selectedIds)
  const accountCurrency = String(node.account.currency_code || baseCurrency).toUpperCase()
  const bodyInteractive = !hasChildren && (isNodeBodyInteractive
    ? Boolean(isNodeBodyInteractive(node, { id, hasChildren, isExpanded, selectionState: state }))
    : Boolean(onNodeBody))
  const defaultAmount = money(
    node.account.balance_original ?? node.account.balance_base ?? 0,
    accountCurrency,
  )
  const displayedAmount = resolveNodeAmount
    ? resolveNodeAmount(node, { id, hasChildren, accountCurrency, defaultAmount, selectionState: state })
    : defaultAmount

  const rowRef = useRef(null)
  const gesture = useRef({ timer: null, startX: 0, startY: 0, dragging: false, suppressClick: false })

  useEffect(() => {
    const row = rowRef.current
    if (!row || !dragEnabled) return undefined

    const clearTimer = () => {
      if (gesture.current.timer) window.clearTimeout(gesture.current.timer)
      gesture.current.timer = null
    }

    const touchStart = (event) => {
      if (event.touches.length !== 1) return
      if (event.target.closest('.accountSelectionControl, .accountDisclosureControl')) return
      const touch = event.touches[0]
      clearTimer()
      gesture.current.startX = touch.clientX
      gesture.current.startY = touch.clientY
      gesture.current.dragging = false
      gesture.current.timer = window.setTimeout(() => {
        gesture.current.dragging = true
        gesture.current.suppressClick = true
        row.closest('.accountSwipeShell')?.scrollTo({ left: 0, behavior: 'auto' })
        window.Telegram?.WebApp?.HapticFeedback?.impactOccurred?.('light')
        onLongPressStart?.(node)
      }, 480)
    }

    const touchMove = (event) => {
      const touch = event.touches[0]
      if (!touch) return
      const dx = touch.clientX - gesture.current.startX
      const dy = touch.clientY - gesture.current.startY
      if (!gesture.current.dragging) {
        if (Math.abs(dx) > 8 || Math.abs(dy) > 8) clearTimer()
        return
      }
      event.preventDefault()
      onLongPressMove?.(touch.clientX, touch.clientY)
    }

    const finish = (event) => {
      clearTimer()
      if (!gesture.current.dragging) return
      event.preventDefault()
      gesture.current.dragging = false
      onLongPressEnd?.()
      window.setTimeout(() => { gesture.current.suppressClick = false }, 0)
    }

    const cancel = () => {
      clearTimer()
      if (gesture.current.dragging) onLongPressEnd?.(true)
      gesture.current.dragging = false
      window.setTimeout(() => { gesture.current.suppressClick = false }, 0)
    }

    row.addEventListener('touchstart', touchStart, { passive: true })
    row.addEventListener('touchmove', touchMove, { passive: false })
    row.addEventListener('touchend', finish, { passive: false })
    row.addEventListener('touchcancel', cancel, { passive: true })
    return () => {
      clearTimer()
      row.removeEventListener('touchstart', touchStart)
      row.removeEventListener('touchmove', touchMove)
      row.removeEventListener('touchend', finish)
      row.removeEventListener('touchcancel', cancel)
    }
  }, [dragEnabled, node, onLongPressEnd, onLongPressMove, onLongPressStart])

  const selectionControl = selectedIds ? (
    <button
      type="button"
      className={`accountSelectionControl is-${state}`}
      onClick={(event) => {
        event.stopPropagation()
        onToggleSelection?.(node, state)
      }}
      aria-label={state === 'all' ? 'Исключить счёт и дочерние счета' : 'Включить счёт и дочерние счета'}
      aria-pressed={state === 'all'}
      data-selection-state={state}
    ><span aria-hidden="true" /></button>
  ) : null

  const identity = (
    <>
      <span className="accountTreeIdentity">
        <strong>{node.account.name}</strong>
        <span>{hasChildren ? `Группа · ${node.children.length}` : `${node.account.account_type || 'Счёт'} · ${accountCurrency}`}</span>
      </span>
      <span className="accountTreeAmounts">
        <strong className="accountTreeAmount sensitive">{privacy ? '••••••' : displayedAmount}</strong>
      </span>
    </>
  )

  const details = !hasChildren
    ? renderAfterNode?.(node, { id, hasChildren, isExpanded, selectionState: state })
    : null

  return (
    <div
      className={`accountTreeNode ${details ? 'hasDetails' : ''} ${dragging ? 'isDragSource' : ''} ${dropTarget ? 'isDropTarget' : ''}`}
      style={{ '--account-depth': depth }}
      data-depth={depth}
      data-account-id={id}
      data-account-role={hasChildren ? 'group' : 'operational'}
    >
      <div className="accountSwipeShell" aria-label="Смахните строку влево для действий; удерживайте для переноса">
        <div className="accountSwipeTrack">
          <div ref={rowRef} className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren groupingAccountRow' : 'operationalAccountRow'}`}>
            {selectionControl}
            {hasChildren ? (
              <button
                type="button"
                className={`accountDisclosureControl ${isExpanded ? 'expanded' : ''}`}
                onClick={(event) => { event.stopPropagation(); onToggleParent(id, node) }}
                aria-label={isExpanded ? 'Свернуть группу счетов' : 'Раскрыть группу счетов'}
                aria-expanded={isExpanded}
              >
                <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
              </button>
            ) : !selectionControl ? <span className="hierarchyChevron accountLeafMarker" aria-hidden="true">•</span> : null}
            {bodyInteractive ? (
              <button type="button" className="homeAccountOpenTarget" onClick={(event) => {
                if (gesture.current.suppressClick) {
                  event.preventDefault()
                  return
                }
                onNodeBody?.(node, false)
              }}>{identity}</button>
            ) : <div className="homeAccountOpenTarget">{identity}</div>}
          </div>
          <div className="accountSwipeActions">
            <button type="button" className="swipeActionButton" onClick={() => onEdit?.(node)}><SwipeActionIcon name="edit" /><span>Изменить</span></button>
            <button type="button" className="swipeActionButton" onClick={() => onArchive?.(node)}><SwipeActionIcon name="archive" /><span>Архив</span></button>
            <button type="button" className="swipeActionButton danger" onClick={() => onDelete?.(node)}><SwipeActionIcon name="delete" /><span>Удалить</span></button>
          </div>
        </div>
      </div>
      {details}
      {hasChildren && isExpanded && <div className="accountTreeChildren">{renderChildren(node.children, depth + 1)}</div>}
    </div>
  )
}

export function AccountTree({
  hierarchy,
  expanded,
  baseCurrency,
  privacy,
  money,
  selectedIds = null,
  onToggleParent,
  onToggleSelection,
  onNodeBody,
  isNodeBodyInteractive,
  renderAfterNode,
  resolveNodeAmount,
  onMoveAccount,
  onEdit,
  onArchive,
  onDelete,
  className = '',
}) {
  const dragRef = useRef({ sourceId: null, targetId: null, currentParentId: null, blocked: new Set() })
  const [draggingId, setDraggingId] = useState(null)
  const [dropTargetId, setDropTargetId] = useState(null)

  const beginDrag = (node) => {
    const sourceId = accountId(node.account)
    dragRef.current = {
      sourceId,
      targetId: null,
      currentParentId: accountParentId(node.account) == null ? null : String(accountParentId(node.account)),
      blocked: new Set(subtreeIds(node)),
    }
    setDraggingId(sourceId)
    setDropTargetId(null)
  }

  const moveDrag = (x, y) => {
    if (!dragRef.current.sourceId) return
    const element = document.elementFromPoint(x, y)
    const candidate = element?.closest?.('[data-account-id]')
    const candidateId = candidate?.dataset?.accountId || null
    const valid = candidateId && !dragRef.current.blocked.has(String(candidateId))
      ? String(candidateId)
      : null
    if (dragRef.current.targetId !== valid) {
      dragRef.current.targetId = valid
      setDropTargetId(valid)
      if (valid) window.Telegram?.WebApp?.HapticFeedback?.selectionChanged?.()
    }
  }

  const endDrag = async (cancelled = false) => {
    const { sourceId, targetId, currentParentId } = dragRef.current
    dragRef.current = { sourceId: null, targetId: null, currentParentId: null, blocked: new Set() }
    setDraggingId(null)
    setDropTargetId(null)
    if (cancelled || !sourceId || !targetId || targetId === currentParentId) return
    window.Telegram?.WebApp?.HapticFeedback?.impactOccurred?.('medium')
    await onMoveAccount?.(sourceId, targetId)
  }

  const renderNodes = (nodes, depth = 0) => nodes.map((node) => {
    const id = accountId(node.account)
    return (
      <TreeRow
        key={id}
        node={node}
        depth={depth}
        expanded={expanded}
        baseCurrency={baseCurrency}
        privacy={privacy}
        money={money}
        selectedIds={selectedIds}
        onToggleParent={onToggleParent}
        onToggleSelection={onToggleSelection}
        onNodeBody={onNodeBody}
        isNodeBodyInteractive={isNodeBodyInteractive}
        renderAfterNode={renderAfterNode}
        resolveNodeAmount={resolveNodeAmount}
        onEdit={onEdit}
        onArchive={onArchive}
        onDelete={onDelete}
        renderChildren={renderNodes}
        dragEnabled={Boolean(onMoveAccount)}
        dragging={draggingId === id}
        dropTarget={dropTargetId === id}
        onLongPressStart={beginDrag}
        onLongPressMove={moveDrag}
        onLongPressEnd={endDrag}
      />
    )
  })

  return <div className={`accountTree ${className}`.trim()}>{renderNodes(hierarchy)}</div>
}
