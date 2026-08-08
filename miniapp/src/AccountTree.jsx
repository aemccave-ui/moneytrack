export function AccountTree({
  hierarchy,
  expanded,
  baseCurrency,
  privacy,
  money,
  onToggleParent,
  onNodeBody,
  excluded = new Set(),
  onToggleLeafIncluded,
  renderAfterNode,
  className = '',
}) {
  const renderNode = (node, depth = 0) => {
    const rawId = node.account.id ?? node.account.account_id
    const id = String(rawId)
    const hasChildren = node.children.length > 0
    const isExpanded = expanded.has(id)
    const isExcluded = !hasChildren && excluded.has(id)
    const accountCurrency = String(node.account.currency_code || baseCurrency).toUpperCase()
    const displayedAmount = hasChildren
      ? money(node.totalBase, baseCurrency)
      : money(node.account.balance_original ?? node.account.balance_base, accountCurrency)

    const leafControl = onToggleLeafIncluded ? (
      <button
        type="button"
        className={`hierarchyChevron currencyAccountMarker explorerNodeControl explorerCheck ${isExcluded ? 'isOff' : 'isOn'}`}
        onClick={() => onToggleLeafIncluded(id, node)}
        aria-label={isExcluded ? 'Включить счёт в баланс' : 'Исключить счёт из баланса'}
        aria-pressed={!isExcluded}
      >
        •
      </button>
    ) : (
      <button
        type="button"
        className="hierarchyChevron"
        onClick={() => onNodeBody(node, false)}
        aria-label="Открыть счёт"
      >
        •
      </button>
    )

    return (
      <div
        className={`accountTreeNode ${isExcluded ? 'explorerTreeNode isExcluded' : ''}`}
        key={id}
        style={{ '--account-depth': depth }}
        data-depth={depth}
      >
        <div className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`}>
          {hasChildren ? (
            <button
              type="button"
              className={`hierarchyChevron ${isExpanded ? 'expanded' : ''}`}
              onClick={() => onToggleParent(id, node)}
              aria-label={isExpanded ? 'Свернуть счёт' : 'Раскрыть счёт'}
              aria-expanded={isExpanded}
            >
              ›
            </button>
          ) : leafControl}
          <button
            type="button"
            className="homeAccountOpenTarget"
            onClick={() => onNodeBody(node, hasChildren)}
          >
            <span className="accountTreeIdentity">
              <strong>{node.account.name}</strong>
              <span>{node.account.account_type || 'Счёт'}{hasChildren ? ` · ${node.children.length}` : ` · ${accountCurrency}`}</span>
            </span>
            <strong className="accountTreeAmount sensitive">{privacy ? '••••••' : displayedAmount}</strong>
          </button>
        </div>
        {hasChildren && isExpanded && (
          <div className="accountTreeChildren">
            {node.children.map((child) => renderNode(child, depth + 1))}
          </div>
        )}
        {renderAfterNode?.(node, { id, hasChildren, isExcluded, isExpanded })}
      </div>
    )
  }

  return <div className={`accountTree ${className}`.trim()}>{hierarchy.map((node) => renderNode(node))}</div>
}
