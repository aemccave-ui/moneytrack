function subtreeFullyExcluded(node, excluded) {
  const id = String(node.account.id ?? node.account.account_id)
  if (!node.children.length) return excluded.has(id)
  return node.children.every((child) => subtreeFullyExcluded(child, excluded))
}

export function AccountTree({
  hierarchy,
  expanded,
  baseCurrency,
  privacy,
  money,
  onToggleParent,
  onNodeBody,
  isNodeBodyInteractive,
  excluded = new Set(),
  onToggleLeafIncluded,
  renderAfterNode,
  resolveNodeAmount,
  className = '',
}) {
  const renderNode = (node, depth = 0) => {
    const rawId = node.account.id ?? node.account.account_id
    const id = String(rawId)
    const hasChildren = node.children.length > 0
    const isExpanded = expanded.has(id)

    const isExcluded = hasChildren
      ? subtreeFullyExcluded(node, excluded)
      : excluded.has(id)

    const accountCurrency = String(
      node.account.currency_code || baseCurrency
    ).toUpperCase()

    const defaultAmount = hasChildren
      ? money(node.totalBase, baseCurrency)
      : money(
          node.account.balance_original ?? node.account.balance_base,
          accountCurrency,
        )

    const displayedAmount = resolveNodeAmount
      ? resolveNodeAmount(node, {
          id,
          hasChildren,
          isExcluded,
          accountCurrency,
          defaultAmount,
        })
      : defaultAmount

    const bodyInteractive = isNodeBodyInteractive
      ? Boolean(isNodeBodyInteractive(node, {
          id,
          hasChildren,
          isExcluded,
          isExpanded,
        }))
      : Boolean(onNodeBody)

    const identity = (
      <>
        <span className="accountTreeIdentity">
          <strong>{node.account.name}</strong>
          <span>
            {node.account.account_type || 'Счёт'}
            {hasChildren
              ? ` · ${node.children.length}`
              : ` · ${accountCurrency}`}
          </span>
        </span>

        <strong className="accountTreeAmount sensitive">
          {privacy ? '••••••' : displayedAmount}
        </strong>
      </>
    )

    const leafControl = onToggleLeafIncluded ? (
      <button
        type="button"
        className={`accountSelectionControl ${isExcluded ? 'isOff' : 'isOn'}`}
        onClick={() => onToggleLeafIncluded(id, node)}
        aria-label={
          isExcluded
            ? 'Включить счёт в баланс'
            : 'Исключить счёт из баланса'
        }
        aria-pressed={!isExcluded}
      >
        <span aria-hidden="true" />
      </button>
    ) : (
      <span
        className="hierarchyChevron accountLeafMarker"
        aria-hidden="true"
      >
        •
      </span>
    )

    return (
      <div
        className={`accountTreeNode ${isExcluded ? 'explorerTreeNode isExcluded' : ''}`}
        key={id}
        style={{ '--account-depth': depth }}
        data-depth={depth}
      >
        <div
          className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`}
        >
          {hasChildren ? (
            <button
              type="button"
              className={`accountDisclosureControl ${isExpanded ? 'expanded' : ''}`}
              onClick={() => onToggleParent(id, node)}
              aria-label={isExpanded ? 'Свернуть счёт' : 'Раскрыть счёт'}
              aria-expanded={isExpanded}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                <path
                  d="M9 6l6 6-6 6"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </button>
          ) : leafControl}

          {bodyInteractive ? (
            <button
              type="button"
              className="homeAccountOpenTarget"
              onClick={() => onNodeBody?.(node, hasChildren)}
            >
              {identity}
            </button>
          ) : (
            <div className="homeAccountOpenTarget">
              {identity}
            </div>
          )}
        </div>

        {hasChildren && isExpanded && (
          <div className="accountTreeChildren">
            {node.children.map((child) => renderNode(child, depth + 1))}
          </div>
        )}

        {renderAfterNode?.(node, {
          id,
          hasChildren,
          isExcluded,
          isExpanded,
        })}
      </div>
    )
  }

  return (
    <div className={`accountTree ${className}`.trim()}>
      {hierarchy.map((node) => renderNode(node))}
    </div>
  )
}
