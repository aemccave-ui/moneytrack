import { useEffect, useMemo, useState } from 'react'
import { getAccounts, getAccountsExplorerSummary, getDashboard } from './api.js'
import { localDateKey } from './date-format.js'
import AccountsScreen from './screens/AccountsScreen.jsx'
import BudgetsScreen from './screens/BudgetsScreen.jsx'
import HomeScreen from './screens/HomeScreen.jsx'
import SettingsScreen from './screens/SettingsScreen.jsx'
import StatisticsScreen from './screens/StatisticsScreen.jsx'

const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency', currency, maximumFractionDigits: 0,
}).format(Number(value || 0))

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

function App() {
  const [dashboard, setDashboard] = useState(null)
  const [accounts, setAccounts] = useState([])
  const [defaultAccount, setDefaultAccount] = useState(null)
  const [homeSnapshotState, setHomeSnapshotState] = useState({ key: '', payload: null, error: '' })
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
    ?? summary.currency
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

  const homeSnapshotRequest = useMemo(() => {
    if (!dashboard || !structuralLeafItems.length) return null
    const today = localDateKey(new Date())
    const dateFrom = String(dashboard?.period?.date_from || `${today.slice(0, 7)}-01`).slice(0, 10)
    const selectedAccountIds = structuralLeafItems.map(accountId).sort((a, b) => Number(a) - Number(b))
    return {
      key: [selectedAccountIds.join(','), dateFrom, today, homeSnapshotRefresh].join('|'),
      selectedAccountIds,
      dateFrom,
      dateTo: today,
    }
  }, [dashboard, structuralLeafItems, homeSnapshotRefresh])

  useEffect(() => {
    if (!homeSnapshotRequest) return undefined
    const controller = new AbortController()
    getAccountsExplorerSummary({
      selectedAccountIds: homeSnapshotRequest.selectedAccountIds,
      dateFrom: homeSnapshotRequest.dateFrom,
      dateTo: homeSnapshotRequest.dateTo,
    }, controller.signal)
      .then((result) => setHomeSnapshotState({ key: homeSnapshotRequest.key, payload: result, error: '' }))
      .catch((reason) => {
        if (reason?.name !== 'AbortError') {
          setHomeSnapshotState({
            key: homeSnapshotRequest.key,
            payload: null,
            error: reason?.message || 'Не удалось загрузить остатки',
          })
        }
      })
    return () => controller.abort()
  }, [homeSnapshotRequest])

  const homeSnapshot = homeSnapshotState.key === homeSnapshotRequest?.key
    ? homeSnapshotState.payload
    : null
  const homeSnapshotError = homeSnapshotState.key === homeSnapshotRequest?.key
    ? homeSnapshotState.error
    : ''
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
  const currentNetWorth = homeSnapshotComplete
    ? canonicalLeafTotal
    : Number(summary.net_worth ?? 0)
  const currentNetWorthCurrency = homeSnapshotComplete
    ? String(homeSnapshot?.base_currency || baseCurrency).toUpperCase()
    : reportCurrency
  const homeBreakdownReady = homeSnapshotComplete

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

  const openScreen = (screen) => {
    setActionsOpen(false)
    setAccountCreateOpen(false)
    setActiveScreen(screen)
  }

  const openExplorer = (id = null) => {
    setExplorerAccountId(id)
    openScreen('accounts')
  }

  const navigation = navigationItems.map((item) => ({
    ...item,
    onClick: item.id === 'accounts'
      ? () => openExplorer()
      : () => openScreen(item.id),
  }))

  if (!dashboard && !error) {
    return <main key="loading" className="app loadingState" aria-busy="true"><div className="skeleton topSkeleton"/><div className="skeleton heroSkeleton"/><div className="skeleton cardSkeleton"/></main>
  }

  if (activeScreen === 'accounts') {
    return (
      <AccountsScreen
        accounts={accounts}
        baseCurrency={baseCurrency}
        privacy={privacy}
        onPrivacyToggle={() => setPrivacy((value) => !value)}
        initialAccountId={explorerAccountId}
        onAccountsChanged={reloadAccounts}
        actionsOpen={actionsOpen}
        onToggleActions={() => setActionsOpen((value) => !value)}
        accountCreateOpen={accountCreateOpen}
        onOpenAccountCreate={() => { setActionsOpen(false); setAccountCreateOpen(true) }}
        onCloseAccountCreate={() => setAccountCreateOpen(false)}
        navigation={navigation}
      />
    )
  }

  if (activeScreen === 'budgets') return <BudgetsScreen navigation={navigation} />
  if (activeScreen === 'stats') return <StatisticsScreen navigation={navigation} />
  if (activeScreen === 'settings') return <SettingsScreen navigation={navigation} />

  return (
    <HomeScreen
      privacy={privacy}
      onPrivacyToggle={() => setPrivacy((value) => !value)}
      error={error}
      currentNetWorth={currentNetWorth}
      currentNetWorthCurrency={currentNetWorthCurrency}
      hidden={hidden}
      dashboard={dashboard}
      summary={summary}
      reportCurrency={reportCurrency}
      baseCurrency={baseCurrency}
      money={money}
      homeBreakdownReady={homeBreakdownReady}
      homeSnapshotError={homeSnapshotError}
      currencyGroups={currencyGroups}
      currencyDistributionTotal={currencyDistributionTotal}
      currencyCaption={currencyCaption}
      currencyBreakdownOpen={currencyBreakdownOpen}
      onCurrencyBreakdownToggle={() => setCurrencyBreakdownOpen((value) => !value)}
      expandedCurrencies={expandedCurrencies}
      onToggleCurrency={(id) => toggleSetItem(setExpandedCurrencies, id)}
      accountHierarchy={accountHierarchy}
      accountDistributionTotal={accountDistributionTotal}
      accountCaption={accountCaption}
      accountBreakdownOpen={accountBreakdownOpen}
      onAccountBreakdownToggle={() => setAccountBreakdownOpen((value) => !value)}
      expandedAccounts={expandedAccounts}
      onToggleAccount={(id) => toggleSetItem(setExpandedAccounts, id)}
      primaryAccount={primaryAccount}
      transactionGroups={transactionGroups}
      onReloadDashboard={reloadDashboard}
      actionsOpen={actionsOpen}
      onToggleActions={() => setActionsOpen((value) => !value)}
      navigation={navigation}
    />
  )
}

export default App
