import { useEffect, useMemo, useState } from 'react'
import { getAccountsExplorerSummary, getTransactions } from './api.js'
import { RecentOperations } from './RecentOperations.jsx'

const parentAccountId = (account) => account.parent_account_id
  ?? account.parent_id
  ?? account.account_parent_id
  ?? account.parentAccountId
  ?? account.parentId
  ?? null

const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency',
  currency,
  maximumFractionDigits: 0,
}).format(Number(value || 0))

const todayLabel = () => new Intl.DateTimeFormat('ru-RU', {
  day: 'numeric', month: 'long', weekday: 'long',
}).format(new Date()).replace(/^./, (char) => char.toUpperCase())

function localDateKey(date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function flattenAccounts(accounts) {
  const byId = new Map()
  const visit = (account, inheritedParentId = null) => {
    const rawId = account?.id ?? account?.account_id
    if (rawId == null) return
    const id = String(rawId)
    const parentId = parentAccountId(account) ?? inheritedParentId
    const normalized = parentId == null ? account : { ...account, parent_id: parentId }
    if (!byId.has(id)) byId.set(id, normalized)
    ;(account.children || account.accounts || []).forEach((child) => visit(child, rawId))
  }
  accounts.forEach((account) => visit(account))
  return [...byId.values()]
}

function buildHierarchy(accounts, baseCurrency) {
  const flatAccounts = flattenAccounts(accounts)
  const byId = new Map(flatAccounts.map((account) => [String(account.id ?? account.account_id), { account, children: [] }]))
  const roots = []

  byId.forEach((node) => {
    const parentId = parentAccountId(node.account)
    const parent = parentId == null ? null : byId.get(String(parentId))
    if (parent && parent !== node) parent.children.push(node)
    else roots.push(node)
  })

  const normalize = (node) => {
    const children = node.children.map(normalize)
      .sort((a, b) => String(a.account.name || '').localeCompare(String(b.account.name || ''), 'ru'))
    const currency = String(node.account.currency_code || baseCurrency).toUpperCase()
    const ownBase = Number(node.account.balance_base
      ?? (currency === baseCurrency ? node.account.balance_original : 0)
      ?? 0)
    return {
      account: node.account,
      children,
      totalBase: ownBase + children.reduce((sum, child) => sum + child.totalBase, 0),
    }
  }

  return roots.map(normalize)
    .filter((node) => Math.abs(node.totalBase) >= 1 || node.children.length > 0)
    .sort((a, b) => Math.abs(b.totalBase) - Math.abs(a.totalBase))
}

function periodDates(period, dateFrom, dateTo) {
  const today = new Date()
  if (period === 'range') return { dateFrom, dateTo }
  const from = new Date(today)
  if (period === 'week') from.setDate(from.getDate() - 6)
  else from.setDate(1)
  return { dateFrom: localDateKey(from), dateTo: localDateKey(today) }
}

function groupTransactions(transactions) {
  const groups = new Map()
  transactions.forEach((transaction) => {
    const key = String(transaction.transaction_date || '').slice(0, 10)
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(transaction)
  })
  return [...groups.entries()].sort(([a], [b]) => b.localeCompare(a))
}

function labelDate(key) {
  const todayKey = localDateKey(new Date())
  const yesterday = new Date()
  yesterday.setDate(yesterday.getDate() - 1)
  if (key === todayKey) return 'Сегодня'
  if (key === localDateKey(yesterday)) return 'Вчера'
  return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' })
    .format(new Date(`${key}T12:00:00`))
}

function LeafOperations({ node, dateFrom, dateTo, baseCurrency, privacy }) {
  const [payload, setPayload] = useState(null)
  const [error, setError] = useState('')
  const [reloadNonce, setReloadNonce] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    setPayload(null)
    setError('')
    getTransactions({
      accountId: node.account.id ?? node.account.account_id,
      dateFrom,
      dateTo,
      includeDescendants: false,
    }, controller.signal)
      .then(setPayload)
      .catch((reason) => {
        if (reason?.name !== 'AbortError') setError(reason?.message || 'Не удалось загрузить операции')
      })
    return () => controller.abort()
  }, [node, dateFrom, dateTo, reloadNonce])

  if (error) return <div className="explorerInlineError" role="alert">{error}</div>
  if (!payload) return <div className="explorerTransactionsLoading">Загрузка операций…</div>

  const transactions = payload.transactions || payload.items || []
  const summary = payload.summary || { income: 0, expense: 0, transfers: 0, count: transactions.length }
  const currency = payload.base_currency || baseCurrency
  const groups = groupTransactions(transactions)

  return (
    <div className="explorerLeafOperations">
      <div className="accountSummary">
        <article><span>Приход</span><strong className="sensitive">{privacy ? '••••' : money(summary.income, currency)}</strong></article>
        <article><span>Расход</span><strong className="sensitive">{privacy ? '••••' : money(summary.expense, currency)}</strong></article>
        <article><span>Переводы</span><strong className="sensitive">{privacy ? '••••' : money(summary.transfers, currency)}</strong></article>
        <article><span>Операций</span><strong>{summary.count}</strong></article>
      </div>
      <RecentOperations
        groups={groups}
        transactions={transactions}
        privacy={privacy}
        baseCurrency={currency}
        money={money}
        dayLabel={labelDate}
        title="Операции"
        emptyLabel="За выбранный период операций нет"
        onDeleted={() => setReloadNonce((value) => value + 1)}
      />
    </div>
  )
}

export default function AccountsExplorer({
  accounts,
  baseCurrency,
  privacy,
  onPrivacyToggle,
  initialAccountId,
}) {
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

  const initialNode = allNodes.find((node) => String(node.account.id ?? node.account.account_id) === String(initialAccountId)) || null
  const [expanded, setExpanded] = useState(() => {
    try {
      return new Set(JSON.parse(localStorage.getItem('moneytrack.accountsExplorer.expanded') || '[]').map(String))
    } catch {
      return new Set()
    }
  })
  const [openLeaves, setOpenLeaves] = useState(() => new Set(initialNode && !initialNode.children.length ? [String(initialNode.account.id ?? initialNode.account.account_id)] : []))
  const [excluded, setExcluded] = useState(() => {
    try {
      return new Set(JSON.parse(localStorage.getItem('moneytrack.accountsExplorer.excluded') || '[]').map(String))
    } catch {
      return new Set()
    }
  })
  const [period, setPeriod] = useState('month')
  const today = new Date()
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1)
  const [dateFrom, setDateFrom] = useState(localDateKey(monthStart))
  const [dateTo, setDateTo] = useState(localDateKey(today))
  const [aggregate, setAggregate] = useState(null)
  const [aggregateError, setAggregateError] = useState('')

  const resolvedPeriod = periodDates(period, dateFrom, dateTo)
  const invalidRange = resolvedPeriod.dateFrom > resolvedPeriod.dateTo

  useEffect(() => {
    if (!initialNode) return
    const id = String(initialNode.account.id ?? initialNode.account.account_id)
    if (initialNode.children.length) {
      setExpanded((current) => new Set([...current, id]))
    }
  }, [initialNode])

  useEffect(() => {
    const controller = new AbortController()
    const excludedIds = [...excluded].sort((a, b) => Number(a) - Number(b))
    setAggregateError('')
    getAccountsExplorerSummary(excludedIds, controller.signal)
      .then(setAggregate)
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setAggregate(null)
          setAggregateError(reason?.message || 'Не удалось пересчитать общий баланс')
        }
      })
    return () => controller.abort()
  }, [excluded])

  const toggleParent = (id) => setExpanded((current) => {
    const next = new Set(current)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    localStorage.setItem('moneytrack.accountsExplorer.expanded', JSON.stringify([...next]))
    return next
  })

  const toggleLeafOperations = (id) => {
    if (excluded.has(id) || invalidRange) return
    setOpenLeaves((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const toggleIncluded = (id) => {
    setExcluded((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      localStorage.setItem('moneytrack.accountsExplorer.excluded', JSON.stringify([...next]))
      return next
    })
    setOpenLeaves((current) => {
      if (!current.has(id)) return current
      const next = new Set(current)
      next.delete(id)
      return next
    })
  }

  const renderNode = (node, depth = 0) => {
    const rawId = node.account.id ?? node.account.account_id
    const id = String(rawId)
    const hasChildren = node.children.length > 0
    const isExpanded = expanded.has(id)
    const isExcluded = !hasChildren && excluded.has(id)
    const operationsOpen = !hasChildren && openLeaves.has(id) && !isExcluded
    const accountCurrency = String(node.account.currency_code || baseCurrency).toUpperCase()
    const displayedAmount = hasChildren
      ? money(node.totalBase, baseCurrency)
      : money(node.account.balance_original ?? node.account.balance_base, accountCurrency)

    return (
      <div className={`accountTreeNode explorerTreeNode ${isExcluded ? 'isExcluded' : ''}`} key={id} style={{ '--account-depth': depth }} data-depth={depth}>
        <div className="hierarchyToggle accountTreeRow explorerHomeTreeRow">
          {hasChildren ? (
            <button type="button" className={`hierarchyChevron explorerNodeControl ${isExpanded ? 'expanded' : ''}`} onClick={() => toggleParent(id)} aria-label={isExpanded ? 'Свернуть счёт' : 'Раскрыть счёт'} aria-expanded={isExpanded}>›</button>
          ) : (
            <button type="button" className={`hierarchyChevron currencyAccountMarker explorerNodeControl explorerCheck ${isExcluded ? 'isOff' : 'isOn'}`} onClick={() => toggleIncluded(id)} aria-label={isExcluded ? 'Включить счёт в баланс' : 'Исключить счёт из баланса'} aria-pressed={!isExcluded}>•</button>
          )}
          <button type="button" className="explorerNodeBody" onClick={() => hasChildren ? toggleParent(id) : toggleLeafOperations(id)}>
            <span className="accountTreeIdentity"><strong>{node.account.name}</strong><span>{node.account.account_type || 'Счёт'}{hasChildren ? ` · ${node.children.length}` : ` · ${accountCurrency}`}</span></span>
            <strong className="accountTreeAmount sensitive">{privacy ? '••••••' : displayedAmount}</strong>
          </button>
        </div>
        {hasChildren && isExpanded && <div className="accountTreeChildren">{node.children.map((child) => renderNode(child, depth + 1))}</div>}
        {operationsOpen && (
          <LeafOperations
            node={node}
            dateFrom={resolvedPeriod.dateFrom}
            dateTo={resolvedPeriod.dateTo}
            baseCurrency={baseCurrency}
            privacy={privacy}
          />
        )}
      </div>
    )
  }

  const displayedTotal = aggregate?.total_base
  const displayCurrency = aggregate?.base_currency || baseCurrency

  return (
    <section className="accountsExplorer">
      <section className="balanceHeader" aria-labelledby="accounts-balance-title">
        <div>
          <div className="todayLabel">{todayLabel()}</div>
          <div className="balanceLabel" id="accounts-balance-title">Общий баланс</div>
          <strong className="balanceValue sensitive">
            {privacy ? '••••••' : displayedTotal == null ? '—' : money(displayedTotal, displayCurrency)}
          </strong>
        </div>
        <button className={`iconButton privacyButton ${privacy ? 'selected' : ''}`} onClick={onPrivacyToggle} aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'} aria-pressed={privacy}>◎</button>
      </section>

      {aggregateError && <div className="explorerInlineError" role="alert">{aggregateError}</div>}

      <div className="periodTabs" role="group" aria-label="Период операций">
        <button type="button" className={period === 'week' ? 'isActive' : ''} onClick={() => setPeriod('week')}>Неделя</button>
        <button type="button" className={period === 'month' ? 'isActive' : ''} onClick={() => setPeriod('month')}>Месяц</button>
        <button type="button" className={period === 'range' ? 'isActive' : ''} onClick={() => setPeriod('range')}>Диапазон</button>
      </div>

      {period === 'range' && (
        <div className="dateRange">
          <input aria-label="Дата начала" type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} />
          <span>—</span>
          <input aria-label="Дата окончания" type="date" value={dateTo} onChange={(event) => setDateTo(event.target.value)} />
        </div>
      )}
      {invalidRange && <div className="explorerInlineError" role="alert">Дата начала должна быть раньше даты окончания.</div>}

      <section className="section accountsSection compactSectionStart explorerAccountsSection">
        <div className="sectionHeader accountsSectionHeader"><h2>Баланс по счетам</h2></div>
        {hierarchy.length
          ? <div className="accountTree explorerAccountTree">{hierarchy.map((node) => renderNode(node))}</div>
          : <div className="emptyCard">Счета пока не созданы</div>}
      </section>

      <div className="historyPlaceholder" aria-hidden="true">Место для истории баланса</div>
    </section>
  )
}
