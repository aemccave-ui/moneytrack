import { useEffect, useMemo, useState } from 'react'
import { getTransactions } from './api.js'
import { RecentOperations } from './RecentOperations.jsx'

const parentAccountId = (account) => account.parent_account_id ?? account.parent_id ?? account.account_parent_id ?? null
const dayKey = (value) => String(value || '').slice(0, 10)
const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency',
  currency,
  maximumFractionDigits: 0,
}).format(Number(value || 0))

function localDateKey(date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function flattenAccounts(accounts) {
  const byId = new Map()

  const visit = (account, inheritedParentId = null) => {
    if (account?.id == null) return
    const id = String(account.id)
    const parentId = parentAccountId(account) ?? inheritedParentId
    const normalized = parentId == null ? account : { ...account, parent_id: parentId }
    if (!byId.has(id)) byId.set(id, normalized)
    const children = account.children || []
    children.forEach((child) => visit(child, account.id))
  }

  accounts.forEach((account) => visit(account))
  return [...byId.values()]
}

function buildHierarchy(accounts, baseCurrency) {
  const flatAccounts = flattenAccounts(accounts)
  const byId = new Map(flatAccounts.map((account) => [String(account.id), { account, children: [] }]))
  const roots = []

  byId.forEach((node) => {
    const parentId = parentAccountId(node.account)
    const parent = parentId == null ? null : byId.get(String(parentId))
    if (parent && parent !== node) parent.children.push(node)
    else roots.push(node)
  })

  const normalize = (node) => {
    const children = node.children
      .map(normalize)
      .sort((a, b) => String(a.account.name || '').localeCompare(String(b.account.name || ''), 'ru'))
    const ownBase = Number(
      node.account.balance_base
      ?? ((node.account.currency_code || baseCurrency) === baseCurrency ? node.account.balance_original : 0)
      ?? 0,
    )
    return {
      account: node.account,
      children,
      totalBase: ownBase + children.reduce((sum, child) => sum + child.totalBase, 0),
    }
  }

  return roots.map(normalize).sort((a, b) => Math.abs(b.totalBase) - Math.abs(a.totalBase))
}

function ancestorIdsFor(node, allNodes) {
  if (!node) return []
  const byId = new Map(allNodes.map((item) => [String(item.account.id), item]))
  const ancestors = []
  let parentId = parentAccountId(node.account)

  while (parentId != null) {
    const parent = byId.get(String(parentId))
    if (!parent) break
    ancestors.push(String(parent.account.id))
    parentId = parentAccountId(parent.account)
  }

  return ancestors
}

function periodDates(period, dateFrom, dateTo) {
  const today = new Date()
  if (period === 'range') return { dateFrom, dateTo }

  const from = new Date(today)
  if (period === 'week') from.setDate(from.getDate() - 6)
  else from.setDate(1)

  return { dateFrom: localDateKey(from), dateTo: localDateKey(today) }
}

export default function AccountsExplorer({ accounts, baseCurrency, privacy, initialAccountId, onBack }) {
  const hierarchy = useMemo(() => buildHierarchy(accounts, baseCurrency), [accounts, baseCurrency])
  const allNodes = useMemo(() => {
    const result = []
    const visit = (node) => {
      result.push(node)
      node.children.forEach(visit)
    }
    hierarchy.forEach(visit)
    return result
  }, [hierarchy])

  const defaultNode = allNodes.find((node) => String(node.account.id) === String(initialAccountId)) || hierarchy[0] || null
  const [selectedId, setSelectedId] = useState(() => defaultNode ? String(defaultNode.account.id) : null)
  const [expanded, setExpanded] = useState(() => {
    let persisted
    try {
      persisted = JSON.parse(localStorage.getItem('moneytrack.accountsExplorer.expanded') || '[]').map(String)
    } catch {
      persisted = []
    }
    return new Set([...persisted, ...ancestorIdsFor(defaultNode, allNodes)])
  })
  const [period, setPeriod] = useState('month')
  const today = new Date()
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1)
  const [dateFrom, setDateFrom] = useState(localDateKey(monthStart))
  const [dateTo, setDateTo] = useState(localDateKey(today))
  const [transactions, setTransactions] = useState(null)
  const [serverSummary, setServerSummary] = useState(null)
  const [serverBaseCurrency, setServerBaseCurrency] = useState(null)
  const [transactionsError, setTransactionsError] = useState('')
  const [reloadNonce, setReloadNonce] = useState(0)

  const selectedNode = allNodes.find((node) => String(node.account.id) === selectedId) || defaultNode
  const resolvedPeriod = periodDates(period, dateFrom, dateTo)
  const invalidRange = resolvedPeriod.dateFrom > resolvedPeriod.dateTo
  const transactionItems = useMemo(() => transactions || [], [transactions])
  const transactionsLoading = transactions === null && !invalidRange && Boolean(selectedNode)
  const displayBaseCurrency = serverBaseCurrency || baseCurrency

  useEffect(() => {
    if (!selectedNode || invalidRange) return undefined

    const controller = new AbortController()
    getTransactions({
      accountId: selectedNode.account.id,
      dateFrom: resolvedPeriod.dateFrom,
      dateTo: resolvedPeriod.dateTo,
      includeDescendants: true,
    }, controller.signal)
      .then((payload) => {
        setTransactions(payload?.transactions || payload?.items || [])
        setServerSummary(payload?.summary || null)
        setServerBaseCurrency(payload?.base_currency || null)
        setTransactionsError('')
      })
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setTransactions([])
          setServerSummary(null)
          setTransactionsError(reason?.message || 'Не удалось загрузить операции')
        }
      })

    return () => controller.abort()
  }, [selectedNode, resolvedPeriod.dateFrom, resolvedPeriod.dateTo, invalidRange, reloadNonce])

  const summary = serverSummary || transactionItems.reduce((acc, tx) => {
    const amount = Math.abs(Number(tx.amount_base ?? tx.amount_original ?? 0))
    if (tx.transaction_type === 'income') acc.income += amount
    else if (tx.transaction_type === 'transfer') acc.transfers += amount
    else acc.expense += amount
    acc.count += 1
    return acc
  }, { income: 0, expense: 0, transfers: 0, count: 0 })

  const groups = useMemo(() => {
    const map = new Map()
    transactionItems.forEach((tx) => {
      const key = dayKey(tx.transaction_date)
      if (!map.has(key)) map.set(key, [])
      map.get(key).push(tx)
    })
    return [...map.entries()].sort(([a], [b]) => b.localeCompare(a))
  }, [transactionItems])

  const labelDate = (key) => {
    const todayKey = localDateKey(new Date())
    const yesterday = new Date()
    yesterday.setDate(yesterday.getDate() - 1)
    if (key === todayKey) return 'Сегодня'
    if (key === localDateKey(yesterday)) return 'Вчера'
    return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' }).format(new Date(`${key}T12:00:00`))
  }

  const markReloading = () => {
    setTransactions(null)
    setServerSummary(null)
    setTransactionsError('')
  }

  const changePeriod = (nextPeriod) => {
    markReloading()
    setPeriod(nextPeriod)
  }

  const changeDateFrom = (value) => {
    markReloading()
    setDateFrom(value)
  }

  const changeDateTo = (value) => {
    markReloading()
    setDateTo(value)
  }

  const toggle = (id) => setExpanded((current) => {
    const next = new Set(current)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    localStorage.setItem('moneytrack.accountsExplorer.expanded', JSON.stringify([...next]))
    return next
  })

  const selectNode = (node) => {
    const id = String(node.account.id)
    markReloading()
    setSelectedId(id)
    setExpanded((current) => {
      const next = new Set([...current, ...ancestorIdsFor(node, allNodes)])
      localStorage.setItem('moneytrack.accountsExplorer.expanded', JSON.stringify([...next]))
      return next
    })
  }

  const renderNode = (node, depth = 0) => {
    const id = String(node.account.id)
    const hasChildren = node.children.length > 0
    const isExpanded = expanded.has(id)
    const currency = node.account.currency_code || displayBaseCurrency

    return (
      <div key={id} className={`explorerAccountNode ${selectedId === id ? 'isSelected' : ''}`}>
        <div className="explorerAccountRow" style={{ '--account-depth': depth }}>
          <button
            type="button"
            className={`explorerAccountToggle ${hasChildren ? '' : 'isLeaf'}`}
            onClick={() => hasChildren && toggle(id)}
            aria-label={hasChildren ? (isExpanded ? 'Свернуть счёт' : 'Раскрыть счёт') : undefined}
          >
            <span className={`hierarchyChevron ${isExpanded ? 'expanded' : ''}`} aria-hidden="true">
              {hasChildren ? '›' : '•'}
            </span>
          </button>
          <button type="button" className="explorerAccountCard" onClick={() => selectNode(node)}>
            <strong>{node.account.name}</strong>
            <span>{node.account.account_type || 'Счёт'} · {hasChildren ? `${node.children.length} дочерн.` : currency}</span>
          </button>
          <strong className="explorerAccountAmount sensitive">
            {privacy ? '••••••' : hasChildren
              ? money(node.totalBase, displayBaseCurrency)
              : money(node.account.balance_original ?? node.account.balance_base, currency)}
          </strong>
        </div>
        {hasChildren && isExpanded && (
          <div className="explorerAccountChildren">
            {node.children.map((child) => renderNode(child, depth + 1))}
          </div>
        )}
      </div>
    )
  }

  return (
    <section className="accountsExplorer">
      <header className="accountsExplorerHeader">
        <div className="accountsExplorerTitle">
          <span>Все деньги по структуре</span>
          <h1>Счета</h1>
        </div>
        <button type="button" className="accountsExplorerBack" onClick={onBack} aria-label="Назад">‹</button>
      </header>

      <div className="periodTabs" role="group" aria-label="Период операций">
        <button type="button" className={period === 'week' ? 'isActive' : ''} onClick={() => changePeriod('week')}>Неделя</button>
        <button type="button" className={period === 'month' ? 'isActive' : ''} onClick={() => changePeriod('month')}>Месяц</button>
        <button type="button" className={period === 'range' ? 'isActive' : ''} onClick={() => changePeriod('range')}>Диапазон</button>
      </div>

      {period === 'range' && (
        <div className="dateRange">
          <input aria-label="Дата начала" type="date" value={dateFrom} onChange={(event) => changeDateFrom(event.target.value)} />
          <span>—</span>
          <input aria-label="Дата окончания" type="date" value={dateTo} onChange={(event) => changeDateTo(event.target.value)} />
        </div>
      )}
      {invalidRange && <div className="explorerInlineError" role="alert">Дата начала должна быть раньше даты окончания.</div>}

      <div className="accountsExplorerTree">
        {hierarchy.map((node) => renderNode(node))}
        {!hierarchy.length && <div className="emptyCard">Счета пока не созданы</div>}
      </div>

      {selectedNode && (
        <section className="explorerSelection">
          <div className="selectionHeader">
            <div>
              <span>Операции выбранного уровня</span>
              <strong>{selectedNode.account.name}</strong>
            </div>
            <em>{selectedNode.children.length ? 'включая дочерние' : selectedNode.account.currency_code || displayBaseCurrency}</em>
          </div>

          <div className="accountSummary" aria-busy={transactionsLoading}>
            <article><span>Приход</span><strong className="sensitive">{privacy ? '••••' : money(summary.income, displayBaseCurrency)}</strong></article>
            <article><span>Расход</span><strong className="sensitive">{privacy ? '••••' : money(summary.expense, displayBaseCurrency)}</strong></article>
            <article><span>Переводы</span><strong className="sensitive">{privacy ? '••••' : money(summary.transfers, displayBaseCurrency)}</strong></article>
            <article><span>Операций</span><strong>{summary.count}</strong></article>
          </div>

          <div className="historyPlaceholder" aria-hidden="true">Место для истории баланса</div>
          {transactionsError && <div className="explorerInlineError" role="alert">{transactionsError}</div>}
          {transactionsLoading && <div className="explorerTransactionsLoading">Загрузка операций…</div>}
          {!transactionsLoading && !transactionsError && (
            <RecentOperations
              groups={groups}
              transactions={transactionItems}
              privacy={privacy}
              baseCurrency={displayBaseCurrency}
              money={money}
              dayLabel={labelDate}
              title="Операции"
              emptyLabel="За выбранный период операций нет"
              onDeleted={() => {
                markReloading()
                setReloadNonce((value) => value + 1)
              }}
            />
          )}
        </section>
      )}
    </section>
  )
}
