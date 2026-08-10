import { useMemo, useState } from 'react'

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
  const [error, setError] = useState('')

  const submit = async (event) => {
    event.preventDefault()
    if (saving) return
    setSaving(true)
    setError('')
    try {
      await onMoveAccount(id, parentId || null)
      onClose()
    } catch (reason) {
      setError(reason?.message || 'Не удалось переместить счёт')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="accountSheetBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <form className="accountSheet" onSubmit={submit} role="dialog" aria-modal="true" aria-label={`Переместить счёт ${node.account.name}`}>
        <header><strong>Переместить счёт</strong><button type="button" onClick={onClose}>×</button></header>
        <p className="accountSheetHint">«{node.account.name}» станет дочерним для выбранного счёта. Верхний уровень убирает родителя.</p>
        <label><span>Родитель</span><select value={parentId} onChange={(event) => setParentId(event.target.value)}><option value="">Без родителя / верхний уровень</option>{options.map((candidate) => <option key={accountId(candidate.account)} value={accountId(candidate.account)}>{candidate.account.name}</option>)}</select></label>
        {error && <div className="explorerInlineError" role="alert">{error}</div>}
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
  onMoveRequest,
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
      className={`accountTreeNode ${details ? 'hasDetails' : ''}`}
      style={{ '--account-depth': depth }}
      data-depth={depth}
      data-account-id={id}
    >
      <div className="accountSwipeShell" aria-label="Смахните строку влево для действий">
        <div className="accountSwipeTrack">
          <div className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`}>
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
              <button type="button" className="homeAccountOpenTarget" onClick={() => onNodeBody?.(node, hasChildren)}>{identity}</button>
            ) : <div className="homeAccountOpenTarget">{identity}</div>}
          </div>
          <div className="accountSwipeActions">
            <button type="button" onClick={() => onMoveRequest?.(node)}>Переместить</button>
            <button type="button" onClick={() => onCopy?.(node)}>Копировать</button>
            <button type="button" onClick={() => onEdit?.(node)}>Изменить</button>
            <button type="button" onClick={() => onArchive?.(node)}>Архив</button>
            <button type="button" className="danger" onClick={() => onDelete?.(node)}>Удалить</button>
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
  resolveOwnAmount,
  onMoveAccount,
  onCopy,
  onEdit,
  onArchive,
  onDelete,
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
      onMoveRequest={onMoveAccount ? setMoveNode : null}
      onCopy={onCopy}
      onEdit={onEdit}
      onArchive={onArchive}
      onDelete={onDelete}
      renderChildren={renderNodes}
    />
  ))

  return (
    <>
      <div className={`accountTree ${className}`.trim()}>{renderNodes(hierarchy)}</div>
      {moveNode && onMoveAccount && <MoveAccountSheet node={moveNode} hierarchy={hierarchy} onMoveAccount={onMoveAccount} onClose={() => setMoveNode(null)} />}
    </>
  )
}
