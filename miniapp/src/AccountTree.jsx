import { useEffect, useRef, useState } from 'react'

const accountId = (account) => String(account.id ?? account.account_id)

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

  const press = useRef({ timer: null, x: 0, y: 0, dragging: false })
  const [dragTarget, setDragTarget] = useState(null)
  const [lifted, setLifted] = useState(false)
  const [swipeX, setSwipeX] = useState(0)
  const actionsOpen = openActionsId === id

  useEffect(() => {
    if (!actionsOpen) {
      setSwipeX(0)
      return undefined
    }
    const timer = window.setTimeout(() => onActionsClose?.(id), 2000)
    return () => window.clearTimeout(timer)
  }, [actionsOpen, id, onActionsClose])

  const clearPress = () => {
    if (press.current.timer) window.clearTimeout(press.current.timer)
    press.current.timer = null
  }

  const pointerDown = (event) => {
    if (event.button != null && event.button !== 0) return
    press.current.x = event.clientX
    press.current.y = event.clientY
    press.current.dragging = false
    clearPress()
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
    if (Math.abs(dx) > Math.abs(dy) && dx < 0) setSwipeX(Math.max(-176, dx))
  }

  const pointerUp = async (event) => {
    clearPress()
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
    if (swipeX < -46) {
      setSwipeX(-176)
      onActionsOpen?.(id)
    } else {
      setSwipeX(0)
      if (actionsOpen) onActionsClose?.(id)
    }
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
      <div className={`accountSwipeShell ${actionsOpen ? 'actionsOpen' : ''}`}>
        <div className="accountSwipeActions" aria-hidden={!actionsOpen}>
          <button type="button" onClick={() => { onCopy?.(node); onActionsClose?.(id) }}>Копировать</button>
          <button type="button" onClick={() => { onEdit?.(node); onActionsClose?.(id) }}>Изменить</button>
          <button type="button" onClick={() => { onArchive?.(node); onActionsClose?.(id) }}>Архив</button>
          <button type="button" className="danger" onClick={() => { onDelete?.(node); onActionsClose?.(id) }}>Удалить</button>
        </div>
        <div
          className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`}
          style={{ transform: `translateX(${actionsOpen ? -176 : swipeX}px)` }}
          onPointerDown={pointerDown}
          onPointerMove={pointerMove}
          onPointerUp={pointerUp}
          onPointerCancel={() => { clearPress(); setLifted(false); setSwipeX(0); setDragTarget(null) }}
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
            <button type="button" className="homeAccountOpenTarget" onClick={() => {
              if (press.current.dragging || Math.abs(swipeX) > 8) return
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
    <div className={`accountTree ${className}`.trim()}>
      {onMoveAccount && <div className="accountRootDropZone" data-account-root-drop="true">Без родителя / верхний уровень</div>}
      {renderNodes(hierarchy)}
    </div>
  )
}
