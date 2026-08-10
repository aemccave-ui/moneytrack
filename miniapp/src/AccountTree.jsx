import { useEffect, useMemo, useRef, useState } from 'react'

const ACTION_REVEAL = 220
const SWIPE_THRESHOLD = 46
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

function flattenNodes(nodes) {
  return nodes.flatMap((node) => [node, ...flattenNodes(node.children)])
}

function selectionState(node, selectedIds) {
  if (!selectedIds) return 'none'
  const ids = subtreeIds(node)
  const selected = ids.filter((id) => selectedIds.has(id)).length
  if (selected === 0) return 'none'
  if (selected === ids.length) return 'all'
  return 'partial'
}

function MoveAccountSheet({ node, hierarchy, onMoveAccount, onClose }) {
  const id = accountId(node.account)
  const blocked = useMemo(() => new Set(subtreeIds(node)), [node])
  const options = useMemo(
    () => flattenNodes(hierarchy).filter((candidate) => !blocked.has(accountId(candidate.account))),
    [blocked, hierarchy],
  )
  const initialParent = accountParentId(node.account)
  const [parentId, setParentId] = useState(initialParent == null ? '' : String(initialParent))
  const [saving, setSaving] = useState(false)

  const submit = async (event) => {
    event.preventDefault()
    if (saving) return
    setSaving(true)
    try {
      await onMoveAccount(id, parentId || null)
      onClose()
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="accountSheetBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <form className="accountSheet" onSubmit={submit} role="dialog" aria-modal="true" aria-label={`Переместить счёт ${node.account.name}`}>
        <header><strong>Переместить счёт</strong><button type="button" onClick={onClose}>×</button></header>
        <p className="accountSheetHint">«{node.account.name}» станет дочерним для выбранного счёта. Выбери верхний уровень, чтобы убрать родителя.</p>
        <label><span>Родитель</span><select value={parentId} onChange={(event) => setParentId(event.target.value)}><option value="">Без родителя / верхний уровень</option>{options.map((candidate) => <option key={accountId(candidate.account)} value={accountId(candidate.account)}>{candidate.account.name}</option>)}</select></label>
        <button className="accountSheetPrimary" type="submit" disabled={saving}>{saving ? 'Перемещение…' : 'Переместить'}</button>
      </form>
    </div>
  )
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
  resolveOwnAmount,
  onMoveAccount,
  onMoveRequest,
  openActionsId,
  onActionsOpen,
  onActionsClose,
  onCopy,
  onEdit,
  onArchive,
  onDelete,
  renderAfterNode,
  renderChildren,
}) {
  const id = accountId(node.account)
  const hasChildren = node.children.length > 0
  const isExpanded = expanded.has(id)
  const state = selectionState(node, selectedIds)
  const accountCurrency = String(node.account.currency_code || baseCurrency).toUpperCase()
  const bodyInteractive = isNodeBodyInteractive
    ? Boolean(isNodeBodyInteractive(node, { id, hasChildren, isExpanded, selectionState: state }))
    : Boolean(onNodeBody)
  const defaultAmount = money(
    node.account.balance_original ?? node.account.balance_base ?? 0,
    accountCurrency,
  )
  const displayedAmount = resolveNodeAmount
    ? resolveNodeAmount(node, { id, hasChildren, accountCurrency, defaultAmount, selectionState: state })
    : defaultAmount
  const ownAmount = resolveOwnAmount?.(node, { id, hasChildren, accountCurrency })

  const press = useRef({ timer: null, x: 0, y: 0, dx: 0, pointerId: null, dragging: false, swiped: false })
  const [dragTarget, setDragTarget] = useState(null)
  const [lifted, setLifted] = useState(false)
  const [swipeX, setSwipeX] = useState(0)
  const actionsOpen = openActionsId === id

  useEffect(() => {
    if (!actionsOpen) return undefined
    const timer = window.setTimeout(() => onActionsClose?.(id), 2000)
    return () => window.clearTimeout(timer)
  }, [actionsOpen, id, onActionsClose])

  const clearPress = () => {
    if (press.current.timer) window.clearTimeout(press.current.timer)
    press.current.timer = null
  }

  const releasePointer = (event) => {
    if (press.current.pointerId != null && event.currentTarget.hasPointerCapture?.(press.current.pointerId)) {
      event.currentTarget.releasePointerCapture(press.current.pointerId)
    }
    press.current.pointerId = null
  }

  const pointerDown = (event) => {
    if (event.button != null && event.button !== 0) return
    press.current.x = event.clientX
    press.current.y = event.clientY
    press.current.dx = 0
    press.current.pointerId = event.pointerId
    press.current.dragging = false
    press.current.swiped = false
    clearPress()
    event.currentTarget.setPointerCapture?.(event.pointerId)
    if (onMoveAccount) {
      press.current.timer = window.setTimeout(() => {
        press.current.dragging = true
        setLifted(true)
        window.Telegram?.WebApp?.HapticFeedback?.impactOccurred?.('light')
      }, 600)
    }
  }

  const pointerMove = (event) => {
    const dx = event.clientX - press.current.x
    const dy = event.clientY - press.current.y
    press.current.dx = dx
    if (press.current.dragging) {
      event.preventDefault()
      const element = document.elementFromPoint(event.clientX, event.clientY)
      if (element?.closest?.('[data-account-root-drop="true"]')) {
        setDragTarget('__ROOT__')
        return
      }
      const candidate = element?.closest?.('[data-account-id]')?.dataset?.accountId || null
      setDragTarget(candidate && candidate !== id ? candidate : null)
      return
    }
    if (Math.abs(dx) > 8 || Math.abs(dy) > 8) clearPress()
    if (Math.abs(dx) > Math.abs(dy) && dx < 0) {
      event.preventDefault()
      if (Math.abs(dx) > 8) press.current.swiped = true
      setSwipeX(Math.max(-ACTION_REVEAL, dx))
    }
  }

  const pointerUp = async (event) => {
    clearPress()
    releasePointer(event)
    if (press.current.dragging) {
      event.preventDefault()
      const target = dragTarget
      press.current.dragging = false
      setLifted(false)
      setDragTarget(null)
      if (target === '__ROOT__') await onMoveAccount?.(id, null)
      else if (target && target !== id) await onMoveAccount?.(id, target)
      return
    }
    if (press.current.dx < -SWIPE_THRESHOLD) {
      press.current.swiped = true
      setSwipeX(0)
      onActionsOpen?.(id)
    } else {
      setSwipeX(0)
      if (actionsOpen) onActionsClose?.(id)
    }
  }

  const pointerCancel = (event) => {
    clearPress()
    releasePointer(event)
    press.current.dragging = false
    press.current.swiped = false
    press.current.dx = 0
    setLifted(false)
    setSwipeX(0)
    setDragTarget(null)
  }

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
        <span>{node.account.account_type || 'Счёт'}{hasChildren ? ` · ${node.children.length}` : ` · ${accountCurrency}`}</span>
      </span>
      <span className="accountTreeAmounts">
        {hasChildren && ownAmount != null && Number(ownAmount.value) !== 0 && (
          <small className="accountOwnAmount sensitive">{privacy ? '••••' : ownAmount.label}</small>
        )}
        <strong className="accountTreeAmount sensitive">{privacy ? '••••••' : displayedAmount}</strong>
      </span>
    </>
  )

  const details = renderAfterNode?.(node, { id, hasChildren, isExpanded, selectionState: state })

  return (
    <div
      className={`accountTreeNode ${lifted ? 'isLifted' : ''} ${details ? 'hasDetails' : ''}`}
      style={{ '--account-depth': depth }}
      data-depth={depth}
      data-account-id={id}
    >
      <div className={`accountSwipeShell ${actionsOpen ? 'actionsOpen' : ''} ${swipeX < 0 ? 'isSwiping' : ''}`}>
        <div className="accountSwipeActions" aria-hidden={!actionsOpen && swipeX >= 0}>
          <button type="button" onClick={() => { onMoveRequest?.(node); onActionsClose?.(id) }}>Переместить</button>
          <button type="button" onClick={() => { onCopy?.(node); onActionsClose?.(id) }}>Копировать</button>
          <button type="button" onClick={() => { onEdit?.(node); onActionsClose?.(id) }}>Изменить</button>
          <button type="button" onClick={() => { onArchive?.(node); onActionsClose?.(id) }}>Архив</button>
          <button type="button" className="danger" onClick={() => { onDelete?.(node); onActionsClose?.(id) }}>Удалить</button>
        </div>
        <div
          className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`}
          style={{ transform: `translateX(${actionsOpen ? -ACTION_REVEAL : swipeX}px)` }}
          onPointerDown={pointerDown}
          onPointerMove={pointerMove}
          onPointerUp={pointerUp}
          onPointerCancel={pointerCancel}
        >
          {selectionControl}
          {hasChildren ? (
            <button
              type="button"
              className={`accountDisclosureControl ${isExpanded ? 'expanded' : ''}`}
              onClick={(event) => { event.stopPropagation(); onToggleParent(id, node) }}
              aria-label={isExpanded ? 'Свернуть счёт' : 'Раскрыть счёт'}
              aria-expanded={isExpanded}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>
            </button>
          ) : !selectionControl ? <span className="hierarchyChevron accountLeafMarker" aria-hidden="true">•</span> : null}
          {bodyInteractive ? (
            <button type="button" className="homeAccountOpenTarget" onClick={(event) => {
              if (press.current.swiped) {
                event.preventDefault()
                press.current.swiped = false
                return
              }
              if (press.current.dragging || Math.abs(swipeX) > 8 || actionsOpen) return
              onNodeBody?.(node, hasChildren)
            }}>{identity}</button>
          ) : <div className="homeAccountOpenTarget">{identity}</div>}
        </div>
      </div>
      {hasChildren && isExpanded && <div className="accountTreeChildren">{renderChildren(node.children, depth + 1)}</div>}
      {details}
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
  resolveOwnAmount,
  onMoveAccount,
  onCopy,
  onEdit,
  onArchive,
  onDelete,
  openActionsId,
  onActionsOpen,
  onActionsClose,
  className = '',
}) {
  const [moveNode, setMoveNode] = useState(null)

  const renderNodes = (nodes, depth = 0) => nodes.map((node) => (
    <TreeRow
      key={accountId(node.account)}
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
      resolveOwnAmount={resolveOwnAmount}
      onMoveAccount={onMoveAccount}
      onMoveRequest={onMoveAccount ? setMoveNode : null}
      openActionsId={openActionsId}
      onActionsOpen={onActionsOpen}
      onActionsClose={onActionsClose}
      onCopy={onCopy}
      onEdit={onEdit}
      onArchive={onArchive}
      onDelete={onDelete}
      renderChildren={renderNodes}
    />
  ))

  return (
    <>
      <div className={`accountTree ${className}`.trim()}>
        {onMoveAccount && <div className="accountRootDropZone" data-account-root-drop="true">Без родителя / верхний уровень</div>}
        {renderNodes(hierarchy)}
      </div>
      {moveNode && onMoveAccount && <MoveAccountSheet node={moveNode} hierarchy={hierarchy} onMoveAccount={onMoveAccount} onClose={() => setMoveNode(null)} />}
    </>
  )
}
