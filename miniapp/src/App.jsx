import { useEffect, useMemo, useState } from 'react'
import { LabBottomNavigation } from '../packages/lab-design-system/navigation.jsx'
import { getAccounts, getAccountsExplorerSummary, getDashboard } from './api.js'
import AccountCreateSheet from './AccountCreateSheet.jsx'
import AccountsExplorer from './AccountsExplorer.jsx'
import { BalanceHero } from './BalanceHero.jsx'
import { RecentOperations } from './RecentOperations.jsx'
import { formatMonthLabel } from './date-format.js'

const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency', currency, maximumFractionDigits: 0,
}).format(Number(value || 0))

const todayLabel = () => new Intl.DateTimeFormat('ru-RU', {
  day: 'numeric', month: 'long', weekday: 'long',
}).format(new Date()).replace(/^./, (char) => char.toUpperCase())

const dayLabel = (date) => new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' })
  .format(new Date(`${String(date).slice(0, 10)}T12:00:00`))

const localDateKey = (date) => {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

const navigationItems = [
  { id: 'home', icon: 'home', label: 'Главная' },
  { id: 'accounts', icon: 'accounts', label: 'Счета' },
  { id: 'budgets', icon: 'budgets', label: 'Бюджеты' },
  { id: 'stats', icon: 'stats', label: 'Статистика' },
  { id: 'settings', icon: 'settings', label: 'Настройки' },
]

const parentAccountId = (account) => account.parent_account_id
  ?? account.parent_id
  ?? account.account_parent_id
  ?? account.parentAccountId
  ?? account.parentId
  ?? null
const accountId = (account) => String(account.id ?? account.account_id)
const segmentColors = ['#1d5559', '#4f9fa3', '#79b7b9', '#a4cccd', '#c6dddd', '#799397']

function flattenAccounts(accounts = []) {
  const byId = new Map()
  const visit = (account, inheritedParentId = null) => {
    const rawId = account?.id ?? account?.account_id
    if (rawId == null) return
    const id = String(rawId)
    const parentId = parentAccountId(account) ?? inheritedParentId
    const normalized = parentId == null ? account : { ...account, parent_id: parentId }
    const existing = byId.get(id)
    byId.set(id, existing ? { ...existing, ...normalized } : normalized)
    ;(account.children || account.accounts || []).forEach((child) => visit(child, rawId))
  }
  accounts.forEach((account) => visit(account))
  return [...byId.values()]
}

function buildHierarchy(accounts, baseCurrency) {
  const byId = new Map(accounts.map((account) => [accountId(account), { account, children: [] }]))
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
    const accountCurrency = String(node.account.currency_code || baseCurrency).toUpperCase()
    const ownBase = Number(node.account.balance_base
      ?? (accountCurrency === baseCurrency ? node.account.balance_original : 0)
      ?? 0)
    const totalBase = children.length
      ? children.reduce((sum, child) => sum + child.totalBase, 0)
      : ownBase
    const leafCount = children.length
      ? children.reduce((sum, child) => sum + child.leafCount, 0)
      : 1
    return { account: node.account, children, totalBase, leafCount }
  }
  return roots.map(normalize)
    .sort((a, b) => Math.abs(b.totalBase) - Math.abs(a.totalBase))
}

function HomeNamedSummary({ items, title }) {
  return (
    <span className="stackNamedCaption" title={title}>
      {items.map((item) => (
        <span className="stackNamedItem" key={item.key}>
          <span className="stackNamedLabel">{item.label}</span>
          <span className="homeCountBadge compactCountBadge" aria-label={`Счетов: ${item.count}`} title={`Счетов: ${item.count}`}>{item.count}</span>
        </span>
      ))}
    </span>
  )
}

function HomeAccountTree({ hierarchy, expanded, onToggle, baseCurrency, hidden }) {
  const renderNode = (node, depth = 0) => {
    const id = accountId(node.account)
    const hasChildren = node.children.length > 0
    const isExpanded = expanded.has(id)
    const currency = String(node.account.currency_code || baseCurrency).toUpperCase()
    return (
      <div className="accountTreeNode" key={id} style={{ '--account-depth': depth }}>
        <button type="button" className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`} onClick={() => hasChildren && onToggle(id)} aria-expanded={hasChildren ? isExpanded : undefined}>
          <span className={`hierarchyChevron ${isExpanded ? 'expanded' : ''}`} aria-hidden="true">{hasChildren ? '›' : '•'}</span>
          <span className="accountTreeIdentity">
            <span className="homeAggregateTitleRow">
              <strong>{node.account.name}</strong>
              {hasChildren && <span className="homeCountBadge" aria-label={`Счетов: ${node.leafCount}`} title={`Счетов: ${node.leafCount}`}>{node.leafCount}</span>}
            </span>
            {!hasChildren && <span className="accountTreeMeta">{node.account.account_type || 'Счёт'} · {currency}</span>}
          </span>
          <strong className="accountTreeAmount sensitive">{hasChildren ? hidden(node.totalBase, baseCurrency) : hidden(node.account.balance_original ?? node.account.balance_base, currency)}</strong>
        </button>
        {hasChildren && isExpanded && <div className="accountTreeChildren">{node.children.map((child) => renderNode(child, depth + 1))}</div>}
      </div>
    )
  }
  return <div className="accountTree">{hierarchy.map((node) => renderNode(node))}</div>
}

function App() {
  const [dashboard, setDashboard] = useState(null)
  const [accounts, setAccounts] = useState([])
  const [defaultAccount, setDefaultAccount] = useState(null)
  const [homeSnapshot, setHomeSnapshot] = useState(null)
  const [homeSnapshotError, setHomeSnapshotError] = useState('')
  const [homeSnapshotRefresh, setHomeSnapshotRefresh] = useState(0)
  const [activeScreen, setActiveScreen] = useState('home')
  const [explorerAccountId, setExplorerAccountId] = useState(null)
  const [privacy, setPrivacy] = useState(false)
  const [actionsOpen, setActionsOpen] = useState(false)
  const [accountCreateOpen, setAccountCreateOpen] = useState(false)
  const [currencyBreakdownOpen, setCurrencyBreakdownOpen] = useState(false)
  const [accountBreakdownOpen, setAccountBreakdownOpen] = useState(false)
  const [expandedCurrencies, setExpandedCurrencies] = useState(() => new Set())
  const [expandedAccounts, setExpandedAccounts] = useState(() => new Set())
  const [error, setError] = useState('')

  const applyAccountData = (accountData) => {
    setAccounts(accountData?.accounts || accountData?.items || [])
    setDefaultAccount(accountData?.default_account ?? accountData?.data?.default_account ?? null)
  }

  useEffect(() => {
    window.Telegram?.WebApp?.ready?.()
    window.Telegram?.WebApp?.expand?.()
    const controller = new AbortController()
    Promise.all([getDashboard(controller.signal), getAccounts(controller.signal)])
      .then(([dash, accountData]) => {
        setDashboard(dash)
        applyAccountData(accountData)
      })
      .catch((reason) => setError(reason.message || 'Не удалось загрузить данные'))
    return () => controller.abort()
  }, [])

  const reloadAccounts = async () => {
    const accountData = await getAccounts()
    applyAccountData(accountData)
    setHomeSnapshotRefresh((value) => value + 1)
  }

  const reloadDashboard = async () => {
    const dash = await getDashboard()
    setDashboard(dash)
    setHomeSnapshotRefresh((value) => value + 1)
  }

  const summary = dashboard?.summary || {}
  const settings = dashboard?.settings || dashboard?.user_settings || summary?.settings || {}
  const baseCurrency = String(
    settings.setbasecurrency
    ?? dashboard?.setbasecurrency
    ?? summary?.setbasecurrency
    ?? summary.base_currency
    ?? summary.currency
    ?? dashboard?.base_currency
    ?? 'EUR',
  ).toUpperCase()
  const reportCurrency = String(
    summary.report_currency
    ?? dashboard?.report_currency
    ?? baseCurrency,
  ).toUpperCase()
  const configuredDefaultAccount = defaultAccount
    ?? settings.setdefaultaccount
    ?? settings.default_account_id
    ?? settings.defaultAccountId
    ?? dashboard?.setdefaultaccount
    ?? dashboard?.default_account_id
    ?? dashboard?.defaultAccountId
    ?? summary?.setdefaultaccount
    ?? summary?.default_account_id
    ?? summary?.defaultAccountId
    ?? null

  const transactions = useMemo(() => dashboard?.latest_operations || [], [dashboard?.latest_operations])
  const hidden = (value, valueCurrency = baseCurrency) => privacy ? '••••••' : money(value, valueCurrency)
  const accountItems = useMemo(() => flattenAccounts(accounts), [accounts])
  const structuralLeafItems = useMemo(() => {
    const parentIds = new Set(
      accountItems
        .map((account) => parentAccountId(account))
        .filter((id) => id != null)
        .map(String),
    )
    return accountItems.filter((account) => !parentIds.has(accountId(account)))
  }, [accountItems])

  useEffect(() => {
    if (!dashboard || !structuralLeafItems.length) {
      setHomeSnapshot(null)
      setHomeSnapshotError('')
      return undefined
    }

    const controller = new AbortController()
    const today = localDateKey(new Date())
    const dateFrom = String(dashboard?.period?.date_from || `${today.slice(0, 7)}-01`).slice(0, 10)
    const selectedAccountIds = structuralLeafItems.map(accountId).sort((a, b) => Number(a) - Number(b))

    setHomeSnapshot(null)
    setHomeSnapshotError('')
    getAccountsExplorerSummary({
      selectedAccountIds,
      dateFrom,
      dateTo: today,
    }, controller.signal)
      .then((result) => setHomeSnapshot(result))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setHomeSnapshotError(reason?.message || 'Не удалось загрузить остатки')
        }
      })
    return () => controller.abort()
  }, [dashboard, structuralLeafItems, homeSnapshotRefresh])

  const homeSnapshotById = useMemo(() => new Map(
    (homeSnapshot?.account_balances || []).map((item) => [String(item.account_id), item]),
  ), [homeSnapshot])
  const homeSnapshotComplete = Boolean(homeSnapshot)
    && Number(homeSnapshot?.snapshot_missing_rate_count ?? homeSnapshot?.missing_rate_count ?? 0) === 0
    && structuralLeafItems.every((account) => homeSnapshotById.has(accountId(account)))

  const canonicalAccountItems = useMemo(() => {
    if (!homeSnapshotComplete) return []
    return accountItems.map((account) => {
      const snapshot = homeSnapshotById.get(accountId(account))
      if (!snapshot) return account
      return {
        ...account,
        balance_original: Number(snapshot.balance_original ?? 0),
        balance_base: Number(snapshot.balance_base ?? 0),
      }
    })
  }, [accountItems, homeSnapshotById, homeSnapshotComplete])

  const operationalAccountItems = useMemo(() => {
    if (!homeSnapshotComplete) return []
    const parentIds = new Set(
      accountItems
        .map((account) => parentAccountId(account))
        .filter((id) => id != null)
        .map(String),
    )
    return accountItems.filter((account) => !parentIds.has(accountId(account))).map((account) => {
      const snapshot = homeSnapshotById.get(accountId(account))
      return {
        ...account,
        balance_original: Number(snapshot?.balance_original ?? 0),
        balance_base: Number(snapshot?.balance_base ?? 0),
      }
    })
  }, [accountItems, homeSnapshotById, homeSnapshotComplete])

  const accountHierarchy = useMemo(
    () => buildHierarchy(canonicalAccountItems, baseCurrency),
    [canonicalAccountItems, baseCurrency],
  )

  const currencyGroups = useMemo(() => {
    const groups = new Map()
    operationalAccountItems.forEach((account) => {
      const code = String(account.currency_code || baseCurrency).toUpperCase()
      const originalBalance = Number(account.balance_original ?? 0)
      const baseBalance = Number(account.balance_base ?? (code === baseCurrency ? originalBalance : 0))
      const group = groups.get(code) || { currency: code, total: 0, totalBase: 0, accounts: [] }
      group.total += originalBalance
      group.totalBase += baseBalance
      group.accounts.push(account)
      groups.set(code, group)
    })
    return [...groups.values()]
      .filter((group) => Math.abs(group.total) > 0.000001 || Math.abs(group.totalBase) > 0.000001)
      .sort((a, b) => Math.abs(b.totalBase) - Math.abs(a.totalBase))
  }, [operationalAccountItems, baseCurrency])

  const primaryAccount = useMemo(() => {
    const configured = configuredDefaultAccount != null && typeof configuredDefaultAccount === 'object'
      ? configuredDefaultAccount.account ?? configuredDefaultAccount
      : configuredDefaultAccount
    const configuredId = configured != null && typeof configured === 'object'
      ? configured.id ?? configured.account_id ?? configured.accountId ?? configured.value ?? configured.uuid
      : configured
    const configuredName = configured != null && typeof configured === 'object'
      ? configured.name ?? configured.account_name ?? configured.accountName ?? configured.label
      : configured
    const normalizedId = String(configuredId ?? '').trim().toLowerCase()
    const normalizedName = String(configuredName ?? '').trim().toLowerCase()
    const account = operationalAccountItems.find((item) => (
      (normalizedId && [item.id, item.account_id, item.accountId, item.uuid].some((value) => String(value ?? '').trim().toLowerCase() === normalizedId))
      || (normalizedName && String(item.name ?? '').trim().toLowerCase() === normalizedName)
    )) ?? operationalAccountItems.find((item) => item.setdefaultaccount === true || item.is_default === true || item.is_default_account === true)
    if (!account) return null
    const currency = String(account.currency_code || baseCurrency).toUpperCase()
    const original = Number(account.balance_original ?? 0)
    return { account, amountBase: Number(account.balance_base ?? (currency === baseCurrency ? original : 0)) }
  }, [operationalAccountItems, baseCurrency, configuredDefaultAccount])

  const canonicalLeafTotal = operationalAccountItems.reduce(
    (sum, account) => sum + Number(account.balance_base ?? 0),
    0,
  )
  const canonicalNetWorth = Number(summary.net_worth ?? 0)
  const comparableCurrency = String(homeSnapshot?.base_currency || baseCurrency).toUpperCase()
  const homeTotalsMismatch = homeSnapshotComplete
    && comparableCurrency === reportCurrency
    && Number.isFinite(canonicalNetWorth)
    && Math.abs(canonicalLeafTotal - canonicalNetWorth) > 0.02
  const homeBreakdownReady = homeSnapshotComplete && !homeTotalsMismatch

  const accountDistributionTotal = accountHierarchy.reduce((sum, node) => sum + Math.abs(node.totalBase), 0)
  const currencyDistributionTotal = currencyGroups.reduce((sum, group) => sum + Math.abs(group.totalBase), 0)
  const currencyCaption = currencyGroups.map((group) => group.currency).join(' · ')
  const accountCaption = accountHierarchy.map((node) => node.account.name).join(' · ')

  const transactionGroups = useMemo(() => {
    const groups = new Map()
    transactions.forEach((transaction) => {
      const key = String(transaction.transaction_date || new Date().toISOString()).slice(0, 10)
      if (!groups.has(key)) groups.set(key, [])
      groups.get(key).push(transaction)
    })
    return [...groups.entries()]
  }, [transactions])

  const toggleSetItem = (setter, id) => setter((current) => {
    const next = new Set(current)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    return next
  })

  const openExplorer = (id = null) => {
    setActionsOpen(false)
    setAccountCreateOpen(false)
    setExplorerAccountId(id)
    setActiveScreen('accounts')
  }

  const openHome = () => {
    setActionsOpen(false)
    setAccountCreateOpen(false)
    setActiveScreen('home')
  }

  const navigation = navigationItems.map((item) => ({
    ...item,
    onClick: item.id === 'accounts'
      ? () => openExplorer()
      : item.id === 'home'
        ? openHome
        : undefined,
  }))

  if (!dashboard && !error) {
    return <main key="loading" className="app loadingState" aria-busy="true"><div className="skeleton topSkeleton"/><div className="skeleton heroSkeleton"/><div className="skeleton cardSkeleton"/></main>
  }

  if (activeScreen === 'accounts') {
    return (
      <main key="accounts" className={`app ${privacy ? 'privacy' : ''}`}>
        <AccountsExplorer
          accounts={accounts}
          baseCurrency={baseCurrency}
          privacy={privacy}
          onPrivacyToggle={() => setPrivacy((value) => !value)}
          initialAccountId={explorerAccountId}
          onAccountsChanged={reloadAccounts}
        />
        <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}>
          <div className="fabActions" aria-hidden={!actionsOpen}>
            <button type="button" className="fabAction" onClick={() => { setActionsOpen(false); setAccountCreateOpen(true) }}><span>Счёт</span><b className="glyph" aria-hidden="true">▤</b></button>
          </div>
          <button type="button" className="fab" onClick={() => setActionsOpen((value) => !value)} aria-label={actionsOpen ? 'Закрыть добавление счёта' : 'Открыть добавление счёта'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button>
        </div>
        {accountCreateOpen && <AccountCreateSheet accounts={accounts} baseCurrency={baseCurrency} onClose={() => setAccountCreateOpen(false)} onSaved={reloadAccounts} />}
        <LabBottomNavigation items={navigation} activeId="accounts" />
      </main>
    )
  }

  const homeBreakdownFallback = homeSnapshotError
    ? <div className="emptyCard" role="alert">Не удалось загрузить актуальные остатки</div>
    : homeTotalsMismatch
      ? <div className="emptyCard" role="alert">Остатки не согласованы с общим балансом</div>
      : <div className="emptyCard">Загрузка остатков…</div>

  return (
    <main key="home" className={`app ${privacy ? 'privacy' : ''}`}>
      <section className="balanceHeader" aria-labelledby="balance-title"><div><div className="todayLabel">{todayLabel()}</div><div className="balanceLabel" id="balance-title">Общий баланс</div><strong className="balanceValue sensitive">{hidden(summary.net_worth, reportCurrency)}</strong></div><button className={`iconButton privacyButton ${privacy ? 'selected' : ''}`} onClick={() => setPrivacy((value) => !value)} aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'} aria-pressed={privacy}>◎</button></section>
      {error && <div className="notice" role="alert">{error}</div>}

      <BalanceHero label={formatMonthLabel(dashboard?.period?.date_from)} result={summary.result_month} income={summary.income_month} expense={summary.expenses_month} privacy={privacy} baseCurrency={baseCurrency} money={money} />

      <section className="section balanceBreakdownSection noSectionTitle">
        <div className="sectionHeader currencyBalancesHeader"><h2>Баланс по валютам</h2></div>
        {homeBreakdownReady ? (currencyGroups.length ? <div className="currencyDistribution">
          <button type="button" className="currencyStackButton compactStackButton" onClick={() => setCurrencyBreakdownOpen((value) => !value)} aria-expanded={currencyBreakdownOpen} aria-controls="currency-breakdown">
            <span className={`hierarchyChevron ${currencyBreakdownOpen ? 'expanded' : ''}`} aria-hidden="true">›</span>
            <span className="currencyStackContent"><span className="currencyStackBar" aria-label="Распределение баланса по валютам">{currencyGroups.map((group, index) => { const width = currencyDistributionTotal > 0 ? Math.abs(group.totalBase) / currencyDistributionTotal * 100 : 100 / currencyGroups.length; return <i key={group.currency} className="currencyStackSegment" style={{ width: `${width}%`, background: segmentColors[index % segmentColors.length] }} /> })}</span><HomeNamedSummary title={currencyCaption} items={currencyGroups.map((group) => ({ key: group.currency, label: group.currency, count: group.accounts.length }))} /></span>
          </button>
          {currencyBreakdownOpen && <div className="currencyHierarchy" id="currency-breakdown">{currencyGroups.map((group) => { const expanded = expandedCurrencies.has(group.currency); return <section className="currencyGroup" key={group.currency}><button type="button" className="hierarchyToggle currencyGroupHeader" onClick={() => toggleSetItem(setExpandedCurrencies, group.currency)} aria-expanded={expanded}><span className={`hierarchyChevron ${expanded ? 'expanded' : ''}`} aria-hidden="true">›</span><span className="homeNamedAggregate"><span className="currencyBadge">{group.currency}</span><span className="homeCountBadge" aria-label={`Счетов: ${group.accounts.length}`} title={`Счетов: ${group.accounts.length}`}>{group.accounts.length}</span></span><strong className="sensitive">{hidden(group.total, group.currency)}</strong></button>{expanded && <div className="currencyGroupChildren">{group.accounts.map((account) => <article className="currencyAccountRow" key={accountId(account)}><span className="hierarchyChevron currencyAccountMarker" aria-hidden="true">•</span><span className="accountTreeIdentity"><strong>{account.name}</strong><span>{account.account_type || 'Счёт'} · {group.currency}</span></span><strong className="sensitive">{hidden(account.balance_original ?? 0, group.currency)}</strong></article>)}</div>}</section> })}</div>}
        </div> : <div className="emptyCard">Нет ненулевых валютных остатков</div>) : homeBreakdownFallback}
      </section>

      <section className="section accountsSection compactSectionStart">
        <div className="sectionHeader accountsSectionHeader"><h2>Баланс по счетам</h2></div>
        {homeBreakdownReady ? <>
          {primaryAccount && <article className="primaryAccountCard"><div><span>Основной счёт · {baseCurrency}</span><strong>{primaryAccount.account.name}</strong></div><strong className="sensitive">{hidden(primaryAccount.amountBase, baseCurrency)}</strong></article>}
          {accountHierarchy.length ? <div className="accountDistribution">
            <button type="button" className="accountStackButton compactStackButton" onClick={() => setAccountBreakdownOpen((value) => !value)} aria-expanded={accountBreakdownOpen} aria-controls="account-breakdown">
              <span className={`hierarchyChevron ${accountBreakdownOpen ? 'expanded' : ''}`} aria-hidden="true">›</span>
              <span className="accountStackContent"><span className="accountStackBar" aria-label="Распределение баланса по счетам">{accountHierarchy.map((node, index) => { const width = accountDistributionTotal > 0 ? Math.abs(node.totalBase) / accountDistributionTotal * 100 : 100 / accountHierarchy.length; return <i key={accountId(node.account)} className="accountStackSegment" style={{ width: `${width}%`, background: segmentColors[index % segmentColors.length] }} /> })}</span><HomeNamedSummary title={accountCaption} items={accountHierarchy.map((node) => ({ key: accountId(node.account), label: node.account.name, count: node.leafCount }))} /></span>
            </button>
            {accountBreakdownOpen && <HomeAccountTree hierarchy={accountHierarchy} expanded={expandedAccounts} onToggle={(id) => toggleSetItem(setExpandedAccounts, id)} baseCurrency={baseCurrency} hidden={hidden} />}
          </div> : <div className="emptyCard">Счета пока не созданы</div>}
        </> : homeBreakdownFallback}
      </section>

      <RecentOperations groups={transactionGroups} transactions={transactions} privacy={privacy} baseCurrency={baseCurrency} money={money} dayLabel={dayLabel} onDeleted={reloadDashboard} />

      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}><div className="fabActions" aria-hidden={!actionsOpen}><button type="button" className="fabAction"><span>Фото</span><b aria-hidden="true">▣</b></button><button type="button" className="fabAction"><span>Голос</span><b aria-hidden="true">●</b></button><button type="button" className="fabAction"><span>Текст</span><b aria-hidden="true">✎</b></button></div><button type="button" className="fab" onClick={() => setActionsOpen((value) => !value)} aria-label={actionsOpen ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button></div>
      <LabBottomNavigation items={navigation} activeId="home" />
    </main>
  )
}

export default App
