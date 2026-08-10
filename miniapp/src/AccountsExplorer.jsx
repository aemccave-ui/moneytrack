import { useEffect, useMemo, useRef, useState } from 'react'
import {
  archiveAccount,
  copyAccount,
  createAccount,
  deleteAccount,
  editAccount,
  getAccountsExplorerSummary,
  getArchivedAccounts,
  getTransactions,
  moveAccount,
  moveAccountOperations,
  previewMoveAccountOperations,
  restoreAccount,
} from './api.js'
import { AccountTree } from './AccountTree.jsx'
import AccountsFilters from './AccountsFilters.jsx'
import { BalanceHero } from './BalanceHero.jsx'
import { RecentOperations } from './RecentOperations.jsx'
import { formatMonthLabel } from './date-format.js'

const accountId = (account) => String(account.id ?? account.account_id)
const accountParentId = (account) => account.parent_account_id
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

function flattenAccounts(accounts = []) {
  const byId = new Map()
  const visit = (account, inheritedParentId = null) => {
    const rawId = account?.id ?? account?.account_id
    if (rawId == null) return
    const id = String(rawId)
    const parentId = accountParentId(account) ?? inheritedParentId
    const normalized = parentId == null ? account : { ...account, parent_id: parentId }
    if (!byId.has(id)) byId.set(id, normalized)
    ;(account.children || account.accounts || []).forEach((child) => visit(child, rawId))
  }
  accounts.forEach((account) => visit(account))
  return [...byId.values()]
}

function buildHierarchy(accounts) {
  const flat = flattenAccounts(accounts)
  const byId = new Map(flat.map((account) => [accountId(account), { account, children: [] }]))
  const roots = []
  byId.forEach((node) => {
    const parentId = accountParentId(node.account)
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
  return roots.map(normalize)
    .sort((a, b) => String(a.account.name || '').localeCompare(String(b.account.name || ''), 'ru'))
}

function nodeIds(node) {
  return [accountId(node.account), ...node.children.flatMap(nodeIds)]
}

function snapshotBase(snapshotById, id) {
  const snapshot = snapshotById.get(String(id))
  if (!snapshot || snapshot.balance_base == null) return null
  const value = Number(snapshot.balance_base)
  return Number.isFinite(value) ? value : null
}

function fullSubtreeTotal(node, snapshotById) {
  const own = snapshotBase(snapshotById, accountId(node.account))
  if (own == null) return null
  let total = own
  for (const child of node.children) {
    const childTotal = fullSubtreeTotal(child, snapshotById)
    if (childTotal == null) return null
    total += childTotal
  }
  return total
}

function selectedTotal(selectedIds, snapshotById) {
  let total = 0
  for (const id of selectedIds) {
    const value = snapshotBase(snapshotById, id)
    if (value == null) return null
    total += value
  }
  return total
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
  if (period === 'month') return formatMonthLabel(`${dateFrom}T12:00:00`)
  if (period === 'week') {
    const from = new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' })
      .format(new Date(`${dateFrom}T12:00:00`))
    const to = new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short', year: 'numeric' })
      .format(new Date(`${dateTo}T12:00:00`))
    return `${from} — ${to}`
  }
  const format = (value) => new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit', month: '2-digit', year: 'numeric',
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

function dayLabel(key) {
  const todayKey = localDateKey(new Date())
  const yesterday = new Date()
  yesterday.setDate(yesterday.getDate() - 1)
  if (key === todayKey) return 'Сегодня'
  if (key === localDateKey(yesterday)) return 'Вчера'
  return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' })
    .format(new Date(`${key}T12:00:00`))
}

function categoryKey(ids) {
  return ids == null ? '*' : [...ids].map(String).sort((a, b) => Number(a) - Number(b)).join(',')
}

function confirmAction(message) {
  if (window.Telegram?.WebApp?.showConfirm) {
    return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  }
  return Promise.resolve(window.confirm(message))
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function OperationsPanel({
  node,
  selectedIds,
  dateFrom,
  dateTo,
  baseCurrency,
  privacy,
  incomeCategoryIds,
  expenseCategoryIds,
}) {
  const id = accountId(node.account)
  const includeDescendants = node.children.length > 0
  const scopeIds = nodeIds(node).filter((value) => selectedIds.has(value))
  const [state, setState] = useState({ key: '', payload: null, error: '' })
  const [reloadNonce, setReloadNonce] = useState(0)
  const requestKey = [
    id,
    includeDescendants,
    scopeIds.join(','),
    dateFrom,
    dateTo,
    categoryKey(incomeCategoryIds),
    categoryKey(expenseCategoryIds),
    reloadNonce,
  ].join('|')
  const payload = state.key === requestKey ? state.payload : null
  const error = state.key === requestKey ? state.error : ''

  useEffect(() => {
    if (!scopeIds.length) return undefined
    const controller = new AbortController()
    getTransactions({
      accountId: id,
      dateFrom,
      dateTo,
      includeDescendants,
      selectedAccountIds: scopeIds,
      incomeCategoryIds,
      expenseCategoryIds,
    }, controller.signal)
      .then((result) => setState({ key: requestKey, payload: result, error: '' }))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setState({ key: requestKey, payload: null, error: reason?.message || 'Не удалось загрузить операции' })
        }
      })
    return () => controller.abort()
  }, [requestKey])

  if (!scopeIds.length) return <div className="explorerTransactionsLoading">Счёт исключён из текущей выборки</div>
  if (error) return <div className="explorerInlineError" role="alert">{error}</div>
  if (!payload) return <div className="explorerTransactionsLoading">Загрузка операций…</div>

  const transactions = payload.transactions || payload.items || []
  const summary = payload.summary || {
    income: payload.income || 0,
    expense: payload.expense || 0,
    result: payload.result || 0,
    count: payload.count ?? transactions.length,
  }
  const currency = payload.summary_currency || payload.base_currency || baseCurrency

  return (
    <div className="explorerAccountOperations">
      <div className="accountPeriodSummary" aria-label="Обороты счёта за выбранный период">
        <div className="accountPeriodMetric resultMetric"><span>Сальдо</span><strong>{privacy ? '••••••' : money(summary.result, currency)}</strong></div>
        <div className="accountPeriodMetric incomeMetric"><span>Доход</span><strong>{privacy ? '••••••' : money(summary.income, currency)}</strong></div>
        <div className="accountPeriodMetric expenseMetric"><span>Расход</span><strong>{privacy ? '••••••' : money(summary.expense, currency)}</strong></div>
      </div>
      <RecentOperations
        groups={groupTransactions(transactions)}
        transactions={transactions}
        privacy={privacy}
        baseCurrency={currency}
        money={money}
        dayLabel={dayLabel}
        title="Операции"
        emptyLabel="За выбранный период операций нет"
        onDeleted={() => setReloadNonce((value) => value + 1)}
      />
    </div>
  )
}

function AccountEditor({ mode, account, accounts, baseCurrency, onClose, onSaved }) {
  const editing = mode === 'edit'
  const [name, setName] = useState(account?.name || '')
  const [accountType, setAccountType] = useState(account?.account_type || 'cash')
  const [currencyCode, setCurrencyCode] = useState(account?.currency_code || baseCurrency)
  const [parentId, setParentId] = useState(accountParentId(account) == null ? '' : String(accountParentId(account)))
  const [saving, setSaving] = useState(false)
  const currentId = account ? accountId(account) : null
  const hierarchy = buildHierarchy(accounts)
  const currentNode = currentId == null ? null : (() => {
    let found = null
    const visit = (node) => {
      if (accountId(node.account) === currentId) found = node
      else node.children.forEach(visit)
    }
    hierarchy.forEach(visit)
    return found
  })()
  const blockedParents = new Set(currentNode ? nodeIds(currentNode) : [])
  const parentOptions = flattenAccounts(accounts).filter((item) => !blockedParents.has(accountId(item)))
  const currencies = [...new Set([baseCurrency, ...flattenAccounts(accounts).map((item) => String(item.currency_code || baseCurrency).toUpperCase())])].sort()

  const submit = async (event) => {
    event.preventDefault()
    if (!name.trim()) return
    setSaving(true)
    try {
      if (editing) {
        await editAccount({ accountId: currentId, name: name.trim(), accountType })
      } else {
        await createAccount({
          name: name.trim(),
          code: null,
          accountType,
          currencyCode,
          parentId: parentId || null,
        })
      }
      await onSaved()
      onClose()
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить счёт')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="accountSheetBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <form className="accountSheet" onSubmit={submit} role="dialog" aria-modal="true" aria-label={editing ? 'Изменить счёт' : 'Добавить новый счёт'}>
        <header><strong>{editing ? 'Изменить счёт' : 'Добавить новый счёт'}</strong><button type="button" onClick={onClose}>×</button></header>
        <label><span>Название</span><input value={name} onChange={(event) => setName(event.target.value)} autoFocus /></label>
        <label><span>Тип</span><input value={accountType} onChange={(event) => setAccountType(event.target.value)} /></label>
        <label><span>Валюта</span><select value={currencyCode} disabled={editing} onChange={(event) => setCurrencyCode(event.target.value)}>{currencies.map((code) => <option key={code} value={code}>{code}</option>)}</select></label>
        {!editing && <label><span>Родитель</span><select value={parentId} onChange={(event) => setParentId(event.target.value)}><option value="">Без родителя</option>{parentOptions.map((item) => <option key={accountId(item)} value={accountId(item)}>{item.name}</option>)}</select></label>}
        {editing && <p className="accountSheetHint">Валюта счёта с историей здесь не меняется. Иерархия редактируется drag & drop.</p>}
        <button className="accountSheetPrimary" type="submit" disabled={saving || !name.trim()}>{saving ? 'Сохранение…' : 'Сохранить'}</button>
      </form>
    </div>
  )
}

function MoveHistorySheet({ source, accounts, deleteAfter, onClose, onComplete }) {
  const sourceId = accountId(source)
  const currency = String(source.currency_code || '').toUpperCase()
  const targets = flattenAccounts(accounts).filter((item) => (
    accountId(item) !== sourceId && String(item.currency_code || '').toUpperCase() === currency
  ))
  const [targetId, setTargetId] = useState(targets[0] ? accountId(targets[0]) : '')
  const [preview, setPreview] = useState(null)
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!targetId) return undefined
    const controller = new AbortController()
    setPreview(null)
    setError('')
    previewMoveAccountOperations(sourceId, targetId, controller.signal)
      .then(setPreview)
      .catch((reason) => {
        if (reason?.name !== 'AbortError') setError(reason?.message || 'Не удалось подготовить перенос')
      })
    return () => controller.abort()
  }, [sourceId, targetId])

  const commit = async () => {
    if (!targetId || !preview) return
    setSaving(true)
    try {
      await moveAccountOperations(sourceId, targetId)
      if (deleteAfter) await deleteAccount(sourceId)
      await onComplete()
      onClose()
    } catch (reason) {
      setError(reason?.message || 'Не удалось перенести операции')
    } finally {
      setSaving(false)
    }
  }

  const operationCount = Number(preview?.operation_count ?? preview?.operations ?? 0)
  const transferCount = Number(preview?.transfer_count ?? preview?.transfers ?? 0)

  return (
    <div className="accountSheetBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <section className="accountSheet" role="dialog" aria-modal="true" aria-label="Перенести операции">
        <header><strong>Перенести операции</strong><button type="button" onClick={onClose}>×</button></header>
        <p>Из <b>{source.name}</b> →</p>
        <label><span>Целевой счёт · {currency}</span><select value={targetId} onChange={(event) => setTargetId(event.target.value)}><option value="">Выберите счёт</option>{targets.map((item) => <option key={accountId(item)} value={accountId(item)}>{item.name}</option>)}</select></label>
        {preview && <div className="movePreview"><strong>Будет перенесено:</strong><span>{operationCount} операций</span><span>{transferCount} переводов</span></div>}
        {error && <div className="explorerInlineError" role="alert">{error}</div>}
        <button type="button" className="accountSheetPrimary" onClick={commit} disabled={!targetId || !preview || saving}>{saving ? 'Перенос…' : deleteAfter ? 'Перенести и удалить счёт' : 'Перенести'}</button>
      </section>
    </div>
  )
}

function ArchivedAccountsSheet({ onClose, onRestored }) {
  const [accounts, setAccounts] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  useEffect(() => {
    const controller = new AbortController()
    getArchivedAccounts(controller.signal)
      .then((result) => setAccounts(result?.accounts || result?.items || []))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') setError(reason?.message || 'Не удалось загрузить архив')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [])

  const restore = async (item) => {
    try {
      await restoreAccount(accountId(item))
      setAccounts((current) => current.filter((account) => accountId(account) !== accountId(item)))
      await onRestored()
    } catch (reason) {
      showError(reason?.message || 'Не удалось восстановить счёт')
    }
  }

  return (
    <div className="accountSheetBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <section className="accountSheet" role="dialog" aria-modal="true" aria-label="Архивные счета">
        <header><strong>Архивные счета</strong><button type="button" onClick={onClose}>×</button></header>
        {loading && <p>Загрузка…</p>}
        {error && <div className="explorerInlineError" role="alert">{error}</div>}
        {!loading && !accounts.length && !error && <p>Архив пуст.</p>}
        <div className="archivedAccountList">{accounts.map((item) => <div key={accountId(item)}><span><strong>{item.name}</strong><small>{item.currency_code}</small></span><button type="button" onClick={() => restore(item)}>Восстановить</button></div>)}</div>
      </section>
    </div>
  )
}

export default function AccountsExplorer({
  accounts,
  baseCurrency,
  privacy,
  onPrivacyToggle,
  initialAccountId,
  onAccountsChanged,
}) {
  const hierarchy = useMemo(() => buildHierarchy(accounts), [accounts])
  const flatAccounts = useMemo(() => flattenAccounts(accounts), [accounts])
  const allAccountIds = useMemo(() => flatAccounts.map(accountId).sort((a, b) => Number(a) - Number(b)), [flatAccounts])
  const previousAllIds = useRef(allAccountIds)
  const [selectedIds, setSelectedIds] = useState(() => new Set(allAccountIds))
  const [expanded, setExpanded] = useState(() => new Set())
  const [openOperations, setOpenOperations] = useState(() => new Set(initialAccountId ? [String(initialAccountId)] : []))
  const [openActionsId, setOpenActionsId] = useState(null)
  const [incomeCategoryIds, setIncomeCategoryIds] = useState(null)
  const [expenseCategoryIds, setExpenseCategoryIds] = useState(null)
  const [period, setPeriod] = useState('month')
  const today = new Date()
  const monthStart = new Date(today.getFullYear(), today.getMonth(), 1)
  const [dateFrom, setDateFrom] = useState(localDateKey(monthStart))
  const [dateTo, setDateTo] = useState(localDateKey(today))
  const [aggregateState, setAggregateState] = useState({ key: '', payload: null, error: '' })
  const [editor, setEditor] = useState(null)
  const [moveHistory, setMoveHistory] = useState(null)
  const [archiveOpen, setArchiveOpen] = useState(false)
  const [snackbar, setSnackbar] = useState(null)

  useEffect(() => {
    const previous = previousAllIds.current
    setSelectedIds((current) => {
      const wasAll = previous.length === current.size && previous.every((id) => current.has(id))
      previousAllIds.current = allAccountIds
      if (wasAll) return new Set(allAccountIds)
      return new Set([...current].filter((id) => allAccountIds.includes(id)))
    })
  }, [allAccountIds.join(',')])

  useEffect(() => {
    if (!snackbar) return undefined
    const timer = window.setTimeout(() => setSnackbar(null), 6000)
    return () => window.clearTimeout(timer)
  }, [snackbar])

  const resolvedPeriod = periodDates(period, dateFrom, dateTo)
  const invalidRange = resolvedPeriod.dateFrom > resolvedPeriod.dateTo
  const selectedAccountIds = useMemo(() => [...selectedIds].sort((a, b) => Number(a) - Number(b)), [selectedIds])
  const aggregateKey = [
    selectedAccountIds.join(','),
    categoryKey(incomeCategoryIds),
    categoryKey(expenseCategoryIds),
    resolvedPeriod.dateFrom,
    resolvedPeriod.dateTo,
  ].join('|')
  const aggregate = aggregateState.key === aggregateKey ? aggregateState.payload : null
  const aggregateError = aggregateState.key === aggregateKey ? aggregateState.error : ''
  const snapshotById = useMemo(() => new Map(
    (aggregate?.account_balances || []).map((item) => [String(item.account_id), item]),
  ), [aggregate])
  const displayCurrency = aggregate?.base_currency || baseCurrency
  const snapshotMissingRateCount = Number(aggregate?.snapshot_missing_rate_count ?? aggregate?.missing_rate_count ?? 0)
  const displayedTotal = aggregate && snapshotMissingRateCount === 0 ? selectedTotal(selectedIds, snapshotById) : null
  const serverTotal = aggregate?.total_base == null ? null : Number(aggregate.total_base)
  const totalMismatch = displayedTotal != null && serverTotal != null && Math.abs(displayedTotal - serverTotal) > 0.01
  const periodSummary = aggregate?.period_summary || {
    income: aggregate?.period_income || 0,
    expense: aggregate?.period_expense || 0,
    result: aggregate?.period_result || 0,
  }

  useEffect(() => {
    if (invalidRange) return undefined
    const controller = new AbortController()
    getAccountsExplorerSummary({
      selectedAccountIds,
      dateFrom: resolvedPeriod.dateFrom,
      dateTo: resolvedPeriod.dateTo,
      incomeCategoryIds,
      expenseCategoryIds,
    }, controller.signal)
      .then((result) => setAggregateState({ key: aggregateKey, payload: result, error: '' }))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') setAggregateState({ key: aggregateKey, payload: null, error: reason?.message || 'Не удалось пересчитать баланс' })
      })
    return () => controller.abort()
  }, [aggregateKey])

  const refreshAccounts = async () => {
    if (onAccountsChanged) await onAccountsChanged()
  }

  const toggleParent = (id) => setExpanded((current) => {
    const next = new Set(current)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    return next
  })

  const toggleSelection = (node, state) => {
    const ids = nodeIds(node)
    setSelectedIds((current) => {
      const next = new Set(current)
      if (state === 'all') ids.forEach((id) => next.delete(id))
      else ids.forEach((id) => next.add(id))
      return next
    })
  }

  const applySelected = (ids) => setSelectedIds(new Set(ids.map(String).filter((id) => allAccountIds.includes(id))))
  const resetAll = () => {
    setSelectedIds(new Set(allAccountIds))
    setIncomeCategoryIds(null)
    setExpenseCategoryIds(null)
  }

  const toggleOperations = (node) => {
    const id = accountId(node.account)
    if (!nodeIds(node).some((value) => selectedIds.has(value))) return
    setOpenOperations((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const findNode = (id) => {
    let found = null
    const visit = (node) => {
      if (accountId(node.account) === String(id)) found = node
      else node.children.forEach(visit)
    }
    hierarchy.forEach(visit)
    return found
  }

  const handleMove = async (sourceId, parentId) => {
    const source = findNode(sourceId)
    const target = parentId == null ? null : findNode(parentId)
    if (!source) return
    if (parentId != null && nodeIds(source).includes(String(parentId))) {
      showError('ACCOUNT_HIERARCHY_CYCLE')
      return
    }
    const previousParentId = accountParentId(source.account)
    try {
      await moveAccount(sourceId, parentId)
      await refreshAccounts()
      setSnackbar({ accountId: sourceId, previousParentId, text: 'Счёт перемещён' })
      if (target && target.children.length === 0) {
        try {
          const preview = await previewMoveAccountOperations(parentId, sourceId)
          const operationCount = Number(preview?.operation_count ?? preview?.operations ?? 0)
          if (operationCount > 0 && await confirmAction(`На счёте ${target.account.name} есть ${operationCount} операций. Перенести их на ${source.account.name}?`)) {
            await moveAccountOperations(parentId, sourceId)
            await refreshAccounts()
          }
        } catch (error) {
          if (error?.message !== 'ACCOUNT_CURRENCY_INCOMPATIBLE') showError(error?.message || 'Не удалось проверить операции родителя')
        }
      }
    } catch (error) {
      showError(error?.message || 'Не удалось переместить счёт')
    }
  }

  const undoMove = async () => {
    if (!snackbar?.accountId) return
    try {
      await moveAccount(snackbar.accountId, snackbar.previousParentId)
      await refreshAccounts()
      setSnackbar(null)
    } catch (error) {
      showError(error?.message || 'Не удалось отменить перемещение')
    }
  }

  const handleCopy = async (node) => {
    try {
      await copyAccount(accountId(node.account))
      await refreshAccounts()
    } catch (error) {
      showError(error?.message || 'Не удалось копировать счёт')
    }
  }

  const handleArchive = async (node) => {
    if (!(await confirmAction(`Архивировать счёт «${node.account.name}»?`))) return
    try {
      await archiveAccount(accountId(node.account))
      await refreshAccounts()
    } catch (error) {
      showError(error?.message || 'Не удалось архивировать счёт')
    }
  }

  const handleDelete = async (node) => {
    if (!(await confirmAction(`Удалить счёт «${node.account.name}»?`))) return
    try {
      await deleteAccount(accountId(node.account))
      await refreshAccounts()
    } catch (error) {
      if (['ACCOUNT_HAS_OPERATIONS', 'ACCOUNT_HAS_REFERENCES', 'ACCOUNT_BALANCE_NOT_ZERO'].includes(error?.message)) {
        setMoveHistory({ source: node.account, deleteAfter: true })
      } else showError(error?.message || 'Не удалось удалить счёт')
    }
  }

  return (
    <section className="accountsExplorer">
      <section className="balanceHeader" aria-labelledby="accounts-balance-title">
        <div><div className="todayLabel">{todayLabel()}</div><div className="balanceLabel" id="accounts-balance-title">Общий баланс</div><strong className="balanceValue sensitive">{privacy ? '••••••' : displayedTotal == null ? '—' : money(displayedTotal, displayCurrency)}</strong></div>
        <button className={`iconButton privacyButton ${privacy ? 'selected' : ''}`} onClick={onPrivacyToggle} aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'} aria-pressed={privacy}>◎</button>
      </section>

      {aggregateError && <div className="explorerInlineError" role="alert">{aggregateError}</div>}
      {snapshotMissingRateCount > 0 && <div className="explorerInlineError" role="alert">Не хватает курса валюты для части snapshot на {resolvedPeriod.dateTo}.</div>}
      {totalMismatch && <div className="explorerInlineError" role="alert">Баланс строк не согласован с серверным итогом.</div>}

      <BalanceHero
        label={selectedPeriodLabel(period, resolvedPeriod.dateFrom, resolvedPeriod.dateTo)}
        result={periodSummary.result}
        income={periodSummary.income}
        expense={periodSummary.expense}
        privacy={privacy}
        baseCurrency={displayCurrency}
        money={money}
      />

      <div className="periodTabs" role="group" aria-label="Период операций">
        <button type="button" className={period === 'week' ? 'isActive' : ''} onClick={() => setPeriod('week')}>Неделя</button>
        <button type="button" className={period === 'month' ? 'isActive' : ''} onClick={() => setPeriod('month')}>Месяц</button>
        <button type="button" className={period === 'range' ? 'isActive' : ''} onClick={() => setPeriod('range')}>Диапазон</button>
      </div>

      {period === 'range' && <div className="dateRange"><input aria-label="Дата начала" type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} /><span>—</span><input aria-label="Дата окончания" type="date" value={dateTo} onChange={(event) => setDateTo(event.target.value)} /></div>}
      {invalidRange && <div className="explorerInlineError" role="alert">Дата начала должна быть раньше даты окончания.</div>}

      <AccountsFilters
        allAccountIds={allAccountIds}
        selectedAccountIds={selectedAccountIds}
        incomeCategoryIds={incomeCategoryIds}
        expenseCategoryIds={expenseCategoryIds}
        onApplySelectedAccounts={applySelected}
        onApplyCategories={({ incomeCategoryIds: incomeIds, expenseCategoryIds: expenseIds }) => { setIncomeCategoryIds(incomeIds); setExpenseCategoryIds(expenseIds) }}
        onResetAll={resetAll}
      />

      <section className="section accountsSection compactSectionStart explorerAccountsSection">
        <div className="accountsExplorerSectionHeader">
          <div><h2>Баланс по счетам</h2><button type="button" className="archivedAccountsLink" onClick={() => setArchiveOpen(true)}>Архивные счета</button></div>
          <button type="button" className="accountsPlusButton" onClick={() => setEditor({ mode: 'create', account: null })} aria-label="Добавить новый счёт">+</button>
        </div>
        {hierarchy.length ? (
          <AccountTree
            hierarchy={hierarchy}
            expanded={expanded}
            baseCurrency={displayCurrency}
            privacy={privacy}
            money={money}
            selectedIds={selectedIds}
            onToggleParent={toggleParent}
            onToggleSelection={toggleSelection}
            onNodeBody={toggleOperations}
            isNodeBodyInteractive={() => true}
            resolveNodeAmount={(node) => {
              if (!aggregate) return '—'
              const value = fullSubtreeTotal(node, snapshotById)
              return value == null ? '—' : money(value, displayCurrency)
            }}
            resolveOwnAmount={(node) => {
              if (!node.children.length || !aggregate) return null
              const value = snapshotBase(snapshotById, accountId(node.account))
              return value == null ? null : { value, label: `(${value >= 0 ? '+' : ''}${money(value, displayCurrency)})` }
            }}
            onMoveAccount={handleMove}
            onCopy={handleCopy}
            onEdit={(node) => setEditor({ mode: 'edit', account: node.account })}
            onArchive={handleArchive}
            onDelete={handleDelete}
            openActionsId={openActionsId}
            onActionsOpen={setOpenActionsId}
            onActionsClose={(id) => setOpenActionsId((current) => current === id ? null : current)}
            className="explorerAccountTree"
            renderAfterNode={(node, { id }) => openOperations.has(id) ? (
              <OperationsPanel
                node={node}
                selectedIds={selectedIds}
                dateFrom={resolvedPeriod.dateFrom}
                dateTo={resolvedPeriod.dateTo}
                baseCurrency={baseCurrency}
                privacy={privacy}
                incomeCategoryIds={incomeCategoryIds}
                expenseCategoryIds={expenseCategoryIds}
              />
            ) : null}
          />
        ) : <div className="emptyCard">Счета пока не созданы</div>}
      </section>

      {editor && <AccountEditor mode={editor.mode} account={editor.account} accounts={accounts} baseCurrency={baseCurrency} onClose={() => setEditor(null)} onSaved={refreshAccounts} />}
      {moveHistory && <MoveHistorySheet source={moveHistory.source} accounts={accounts} deleteAfter={moveHistory.deleteAfter} onClose={() => setMoveHistory(null)} onComplete={refreshAccounts} />}
      {archiveOpen && <ArchivedAccountsSheet onClose={() => setArchiveOpen(false)} onRestored={refreshAccounts} />}
      {snackbar && <div className="accountSnackbar" role="status"><span>{snackbar.text}</span><button type="button" onClick={undoMove}>Отменить</button></div>}
    </section>
  )
}
