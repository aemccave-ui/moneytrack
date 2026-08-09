import { useEffect, useMemo, useState } from 'react'
import { getAccountsExplorerSummary, getTransactions } from './api.js'
import { RecentOperations } from './RecentOperations.jsx'
import { AccountTree } from './AccountTree.jsx'
import { BalanceHero } from './BalanceHero.jsx'
import { formatMonthLabel } from './date-format.js'

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

function buildHierarchy(accounts) {
  const flatAccounts = flattenAccounts(accounts)
  const byId = new Map(flatAccounts.map((account) => [
    String(account.id ?? account.account_id),
    { account, children: [] },
  ]))
  const roots = []

  byId.forEach((node) => {
    const parentId = parentAccountId(node.account)
    const parent = parentId == null ? null : byId.get(String(parentId))
    if (parent && parent !== node) parent.children.push(node)
    else roots.push(node)
  })

  const normalize = (node) => ({
    account: node.account,
    children: node.children
      .map(normalize)
      .sort((a, b) => String(a.account.name || '').localeCompare(String(b.account.name || ''), 'ru')),
  })

  return roots
    .map(normalize)
    .sort((a, b) => String(a.account.name || '').localeCompare(String(b.account.name || ''), 'ru'))
}

function subtreeFullyExcluded(node, excluded) {
  const id = String(node.account.id ?? node.account.account_id)
  if (!node.children.length) return excluded.has(id)
  return node.children.every((child) => subtreeFullyExcluded(child, excluded))
}

function snapshotBase(snapshotById, id) {
  const snapshot = snapshotById.get(String(id))
  if (!snapshot || snapshot.balance_base == null) return null
  const value = Number(snapshot.balance_base)
  return Number.isFinite(value) ? value : null
}

function includedSubtreeTotal(node, excluded, snapshotById) {
  const id = String(node.account.id ?? node.account.account_id)

  if (!node.children.length) {
    if (excluded.has(id)) return 0
    return snapshotBase(snapshotById, id)
  }

  if (subtreeFullyExcluded(node, excluded)) return 0

  let total = 0
  for (const child of node.children) {
    const childTotal = includedSubtreeTotal(child, excluded, snapshotById)
    if (childTotal == null) return null
    total += childTotal
  }
  return total
}

function selectedLeafTotal(hierarchy, excluded, snapshotById) {
  let total = 0
  let missing = false

  const visit = (node) => {
    const id = String(node.account.id ?? node.account.account_id)
    if (node.children.length) {
      node.children.forEach(visit)
      return
    }
    if (excluded.has(id)) return
    const value = snapshotBase(snapshotById, id)
    if (value == null) missing = true
    else total += value
  }

  hierarchy.forEach(visit)
  return missing ? null : total
}

function periodDates(period, dateFrom, dateTo) {
  const today = new Date()
  if (period === 'range') return { dateFrom, dateTo }
  const from = new Date(today)
  if (period === 'week') from.setDate(from.getDate() - 6)
  else from.setDate(1)
  return { dateFrom: localDateKey(from), dateTo: localDateKey(today) }
}

function selectedPeriodLabel(period, dateFrom, dateTo) {
  if (period === 'month') {
    return formatMonthLabel(`${dateFrom}T12:00:00`)
  }

  const from = new Date(`${dateFrom}T12:00:00`)
  const to = new Date(`${dateTo}T12:00:00`)

  if (period === 'week') {
    const sameMonth = (
      from.getFullYear() === to.getFullYear()
      && from.getMonth() === to.getMonth()
    )

    if (sameMonth) {
      const monthYear = new Intl.DateTimeFormat('ru-RU', {
        month: 'long',
        year: 'numeric',
      }).format(to)
        .replace(/\sГ\.$/u, ' г.')
        .replace(/\sг\.$/u, ' г.')

      return `${from.getDate()}–${to.getDate()} ${monthYear}`
    }

    const left = new Intl.DateTimeFormat('ru-RU', {
      day: 'numeric',
      month: 'short',
    }).format(from)

    const right = new Intl.DateTimeFormat('ru-RU', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    }).format(to)
      .replace(/\sГ\.$/u, ' г.')
      .replace(/\sг\.$/u, ' г.')

    return `${left} — ${right}`
  }

  const format = (value) => new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(new Date(`${value}T12:00:00`))

  return `${format(dateFrom)} — ${format(dateTo)}`
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
  const accountId = String(node.account.id ?? node.account.account_id)
  const [requestState, setRequestState] = useState({ key: '', payload: null, error: '' })
  const [reloadNonce, setReloadNonce] = useState(0)
  const requestKey = `${accountId}:${dateFrom}:${dateTo}:${reloadNonce}`
  const payload = requestState.key === requestKey ? requestState.payload : null
  const error = requestState.key === requestKey ? requestState.error : ''

  useEffect(() => {
    const controller = new AbortController()
    getTransactions({
      accountId,
      dateFrom,
      dateTo,
      includeDescendants: false,
    }, controller.signal)
      .then((result) => setRequestState({ key: requestKey, payload: result, error: '' }))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setRequestState({ key: requestKey, payload: null, error: reason?.message || 'Не удалось загрузить операции' })
        }
      })
    return () => controller.abort()
  }, [accountId, dateFrom, dateTo, reloadNonce, requestKey])

  if (error) return <div className="explorerInlineError" role="alert">{error}</div>
  if (!payload) return <div className="explorerTransactionsLoading">Загрузка операций…</div>

  const transactions = payload.transactions || payload.items || []
  const summary = payload.summary || { income: 0, expense: 0, transfers: 0, count: transactions.length }
  const currency = payload.summary_currency || payload.base_currency || baseCurrency
  const groups = groupTransactions(transactions)

  return (
    <div className="explorerLeafOperations">
      <div className="accountPeriodSummary" aria-label="Обороты счета за выбранный период">
        <div className="accountPeriodMetric resultMetric">
          <span>Сальдо</span>
          <strong className="sensitive">{privacy ? '••••••' : money(summary.result, currency)}</strong>
        </div>
        <div className="accountPeriodMetric incomeMetric">
          <span>Доход</span>
          <strong className="sensitive">{privacy ? '••••••' : money(summary.income, currency)}</strong>
        </div>
        <div className="accountPeriodMetric expenseMetric">
          <span>Расход</span>
          <strong className="sensitive">{privacy ? '••••••' : money(summary.expense, currency)}</strong>
        </div>
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
  const hierarchy = useMemo(() => buildHierarchy(accounts), [accounts])
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
    let stored
    try {
      stored = new Set(JSON.parse(localStorage.getItem('moneytrack.accountsExplorer.expanded') || '[]').map(String))
    } catch {
      stored = new Set()
    }
    if (initialNode?.children.length) stored.add(String(initialNode.account.id ?? initialNode.account.account_id))
    return stored
  })
  const [openLeaves, setOpenLeaves] = useState(() => new Set(initialNode && !initialNode.children.length ? [String(initialNode.account.id ?? initialNode.account.account_id)] : []))
  const [excluded, setExcluded] = useState(() => {
    try {
      localStorage.removeItem('moneytrack.accountsExplorer.excluded')
    } catch {
      // Storage may be unavailable in restricted WebView contexts.
    }
    return new Set()
  })
  const [period, setPeriod] = useState('month')
  const today = new Date()
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1)
  const [dateFrom, setDateFrom] = useState(localDateKey(monthStart))
  const [dateTo, setDateTo] = useState(localDateKey(today))
  const [aggregateState, setAggregateState] = useState({ key: '', payload: null, error: '' })

  const resolvedPeriod = periodDates(period, dateFrom, dateTo)
  const invalidRange = resolvedPeriod.dateFrom > resolvedPeriod.dateTo
  const excludedIds = useMemo(() => [...excluded].sort((a, b) => Number(a) - Number(b)), [excluded])
  const aggregateKey = [
    excludedIds.join(','),
    resolvedPeriod.dateFrom,
    resolvedPeriod.dateTo,
  ].join('|')

  const aggregate = aggregateState.key === aggregateKey ? aggregateState.payload : null
  const aggregateError = aggregateState.key === aggregateKey ? aggregateState.error : ''
  const snapshotById = useMemo(() => new Map(
    (aggregate?.account_balances || []).map((item) => [String(item.account_id), item]),
  ), [aggregate])
  const displayCurrency = aggregate?.base_currency || baseCurrency
  const snapshotMissingRateCount = Number(aggregate?.snapshot_missing_rate_count || 0)
  const displayedTotal = aggregate && snapshotMissingRateCount === 0
    ? selectedLeafTotal(hierarchy, excluded, snapshotById)
    : null
  const serverTotal = aggregate?.total_base == null ? null : Number(aggregate.total_base)
  const totalMismatch = displayedTotal != null
    && serverTotal != null
    && Math.abs(displayedTotal - serverTotal) > 0.01

  useEffect(() => {
    const controller = new AbortController()
    if (invalidRange) return () => controller.abort()

    getAccountsExplorerSummary(
      excludedIds,
      resolvedPeriod.dateFrom,
      resolvedPeriod.dateTo,
      controller.signal,
    )
      .then((result) => setAggregateState({ key: aggregateKey, payload: result, error: '' }))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setAggregateState({ key: aggregateKey, payload: null, error: reason?.message || 'Не удалось пересчитать общий баланс' })
        }
      })
    return () => controller.abort()
  }, [aggregateKey, excludedIds, invalidRange, resolvedPeriod.dateFrom, resolvedPeriod.dateTo])

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
      return next
    })
    setOpenLeaves((current) => {
      if (!current.has(id)) return current
      const next = new Set(current)
      next.delete(id)
      return next
    })
  }

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
      {snapshotMissingRateCount > 0 && (
        <div className="explorerInlineError" role="alert">
          Не удалось пересчитать часть счетов в {displayCurrency} на выбранную дату: отсутствует курс валюты.
        </div>
      )}
      {totalMismatch && (
        <div className="explorerInlineError" role="alert">
          Баланс счетов не согласован с серверным итогом. Показана сумма строк счетов.
        </div>
      )}

      <BalanceHero
        label={selectedPeriodLabel(period, resolvedPeriod.dateFrom, resolvedPeriod.dateTo)}
        result={aggregate?.period_summary?.result}
        income={aggregate?.period_summary?.income}
        expense={aggregate?.period_summary?.expense}
        privacy={privacy}
        baseCurrency={displayCurrency}
        money={money}
      />

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
        {hierarchy.length ? (
          <AccountTree
            hierarchy={hierarchy}
            expanded={expanded}
            baseCurrency={displayCurrency}
            privacy={privacy}
            money={money}
            resolveNodeAmount={(node, { id, hasChildren }) => {
              if (!aggregate) return '—'
              const value = hasChildren
                ? includedSubtreeTotal(node, excluded, snapshotById)
                : snapshotBase(snapshotById, id)
              return value == null ? '—' : money(value, displayCurrency)
            }}
            excluded={excluded}
            onToggleParent={(id) => toggleParent(id)}
            onToggleLeafIncluded={(id) => toggleIncluded(id)}
            isNodeBodyInteractive={() => true}
            onNodeBody={(node, hasChildren) => {
              const id = String(node.account.id ?? node.account.account_id)
              if (hasChildren) toggleParent(id)
              else toggleLeafOperations(id)
            }}
            className="explorerAccountTree"
            renderAfterNode={(node, { id, hasChildren, isExcluded }) => (
              !hasChildren && openLeaves.has(id) && !isExcluded ? (
                <LeafOperations
                  node={node}
                  dateFrom={resolvedPeriod.dateFrom}
                  dateTo={resolvedPeriod.dateTo}
                  baseCurrency={baseCurrency}
                  privacy={privacy}
                />
              ) : null
            )}
          />
        ) : <div className="emptyCard">Счета пока не созданы</div>}
      </section>
    </section>
  )
}
