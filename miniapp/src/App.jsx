import { useEffect, useMemo, useRef, useState } from 'react'
import { LabBottomNavigation } from '../packages/lab-design-system/navigation.jsx'
import { getAccounts, getDashboard } from './api.js'

const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency', currency, maximumFractionDigits: 0,
}).format(Number(value || 0))

const monthLabel = (date) => new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric' })
  .format(date ? new Date(date) : new Date())

const todayLabel = () => new Intl.DateTimeFormat('ru-RU', {
  day: 'numeric', month: 'long', weekday: 'long',
}).format(new Date()).replace(/^./, (char) => char.toUpperCase())

const dayLabel = (date) => new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' })
  .format(new Date(date))

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
const segmentColors = ['#1d5559', '#4f9fa3', '#79b7b9', '#a4cccd', '#c6dddd', '#799397']

function Glyph({ children }) {
  return <span className="glyph" aria-hidden="true">{children}</span>
}

function App() {
  const [dashboard, setDashboard] = useState(null)
  const [accounts, setAccounts] = useState([])
  const [defaultAccount, setDefaultAccount] = useState(null)
  const [privacy, setPrivacy] = useState(false)
  const [actionsOpen, setActionsOpen] = useState(false)
  const [currencyBreakdownOpen, setCurrencyBreakdownOpen] = useState(false)
  const [accountBreakdownOpen, setAccountBreakdownOpen] = useState(false)
  const [accountCaptionOverflow, setAccountCaptionOverflow] = useState(false)
  const accountCaptionMetaRef = useRef(null)
  const accountCaptionRef = useRef(null)
  const [expandedCurrencies, setExpandedCurrencies] = useState(() => new Set())
  const [expandedAccounts, setExpandedAccounts] = useState(() => new Set())
  const [error, setError] = useState('')

  useEffect(() => {
    window.Telegram?.WebApp?.ready?.()
    window.Telegram?.WebApp?.expand?.()
    const controller = new AbortController()
    Promise.all([getDashboard(controller.signal), getAccounts(controller.signal)])
      .then(([dash, accountData]) => {
        setDashboard(dash)
        setAccounts(accountData?.accounts || accountData?.items || [])
        setDefaultAccount(
          accountData?.default_account
          ?? accountData?.data?.default_account
          ?? null,
        )
      })
      .catch((reason) => setError(reason.message || 'Не удалось загрузить данные'))
    return () => controller.abort()
  }, [])

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

  const accountItems = useMemo(() => {
    const flattened = []
    const visit = (account, inheritedParentId = null) => {
      const normalized = inheritedParentId == null || parentAccountId(account) != null
        ? account
        : { ...account, parent_id: inheritedParentId }
      flattened.push(normalized)
      const id = account.id ?? account.account_id
      ;(account.children || account.accounts || []).forEach((child) => visit(child, id))
    }
    accounts.forEach((account) => visit(account))
    return flattened
  }, [accounts])

  const currencyGroups = (() => {
    const groups = new Map()
    accountItems.forEach((account) => {
      const code = account.currency_code || baseCurrency
      const originalBalance = Number(account.balance_original ?? account.balance_base ?? 0)
      const baseBalance = Number(account.balance_base ?? (code === baseCurrency ? originalBalance : 0))
      const group = groups.get(code) || { currency: code, total: 0, totalBase: 0, accounts: [] }
      group.total += originalBalance
      group.totalBase += baseBalance
      group.accounts.push(account)
      groups.set(code, group)
    })
    return [...groups.values()]
      .filter((group) => Math.abs(group.total) >= 1)
      .sort((a, b) => Math.abs(b.totalBase) - Math.abs(a.totalBase))
  })()

  const accountHierarchy = useMemo(() => {
    const byId = new Map(accountItems.map((account) => [String(account.id ?? account.account_id), { account, children: [] }]))
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
      const ownBase = Number(node.account.balance_base
        ?? ((node.account.currency_code || baseCurrency) === baseCurrency ? node.account.balance_original : 0)
        ?? 0)
      const totalBase = ownBase + children.reduce((sum, child) => sum + child.totalBase, 0)
      return { account: node.account, children, totalBase }
    }
    return roots.map(normalize)
      .filter((node) => Math.abs(node.totalBase) >= 1 || node.children.length > 0)
      .sort((a, b) => Math.abs(b.totalBase) - Math.abs(a.totalBase))
  }, [accountItems, baseCurrency])

  const primaryAccount = (() => {
    const configured = configuredDefaultAccount != null
      && typeof configuredDefaultAccount === 'object'
      ? configuredDefaultAccount.account ?? configuredDefaultAccount
      : configuredDefaultAccount

    const configuredId = configured != null
      && typeof configured === 'object'
      ? configured.id
        ?? configured.account_id
        ?? configured.accountId
        ?? configured.value
        ?? configured.uuid
      : configured

    const configuredName = configured != null
      && typeof configured === 'object'
      ? configured.name
        ?? configured.account_name
        ?? configured.accountName
        ?? configured.label
      : configured

    const normalizedId = String(configuredId ?? '').trim().toLowerCase()
    const normalizedName = String(configuredName ?? '').trim().toLowerCase()

    const account = accountItems.find((item) => (
      (normalizedId && (
        String(item.id ?? '').trim().toLowerCase() === normalizedId
        || String(item.account_id ?? '').trim().toLowerCase() === normalizedId
        || String(item.accountId ?? '').trim().toLowerCase() === normalizedId
        || String(item.uuid ?? '').trim().toLowerCase() === normalizedId
      ))
      || (normalizedName
        && String(item.name ?? '').trim().toLowerCase() === normalizedName)
    )) ?? accountItems.find((item) => (
      item.setdefaultaccount === true
      || item.is_default === true
      || item.is_default_account === true
    ))

    if (!account) return null

    const accountCurrency = String(account.currency_code || baseCurrency).toUpperCase()
    const originalAmount = Number(account.balance_original ?? account.balance ?? 0)

    return {
      account,
      amountBase: Number(
        account.balance_base
        ?? (accountCurrency === baseCurrency ? originalAmount : 0),
      ),
    }
  })()

  const accountDistributionTotal = accountHierarchy.reduce((sum, node) => sum + Math.abs(node.totalBase), 0)
  const currencyDistributionTotal = currencyGroups.reduce((sum, group) => sum + Math.abs(group.totalBase), 0)
  const currencyCaption = currencyGroups.map((group) => group.currency).join(' · ')
  const accountCaption = accountHierarchy.map((node) => node.account.name).join(' · ')

  useEffect(() => {
    const meta = accountCaptionMetaRef.current
    const label = accountCaptionRef.current
    if (!meta || !label) return undefined

    const updateOverflow = () => {
      setAccountCaptionOverflow(label.scrollWidth > meta.clientWidth)
    }

    const frame = requestAnimationFrame(updateOverflow)
    const observer = new ResizeObserver(updateOverflow)
    observer.observe(meta)
    return () => {
      cancelAnimationFrame(frame)
      observer.disconnect()
    }
  }, [accountCaption])

  const transactionGroups = useMemo(() => {
    const groups = new Map()
    transactions.forEach((transaction) => {
      const date = transaction.transaction_date || new Date().toISOString()
      const key = String(date).slice(0, 10)
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

  const renderAccountNode = (node, depth = 0) => {
    const id = String(node.account.id)
    const hasChildren = node.children.length > 0
    const expanded = expandedAccounts.has(id)
    const accountCurrency = node.account.currency_code || baseCurrency
    const displayedAmount = hasChildren
      ? hidden(node.totalBase, baseCurrency)
      : hidden(node.account.balance_original ?? node.account.balance_base, accountCurrency)
    return (
      <div className="accountTreeNode" key={id} style={{ '--account-depth': depth }} data-depth={depth}>
        <button type="button" className={`hierarchyToggle accountTreeRow ${hasChildren ? 'hasChildren' : ''}`}
          onClick={() => hasChildren && toggleSetItem(setExpandedAccounts, id)} aria-expanded={hasChildren ? expanded : undefined}>
          <span className={`hierarchyChevron ${expanded ? 'expanded' : ''}`} aria-hidden="true">{hasChildren ? '›' : '•'}</span>
          <span className="accountTreeIdentity"><strong>{node.account.name}</strong><span>{node.account.account_type || 'Счёт'}{hasChildren ? ` · ${node.children.length}` : ` · ${accountCurrency}`}</span></span>
          <strong className="accountTreeAmount sensitive">{displayedAmount}</strong>
        </button>
        {hasChildren && expanded && <div className="accountTreeChildren">{node.children.map((child) => renderAccountNode(child, depth + 1))}</div>}
      </div>
    )
  }

  if (!dashboard && !error) return <main className="app loadingState" aria-busy="true"><div className="skeleton topSkeleton"/><div className="skeleton heroSkeleton"/><div className="skeleton cardSkeleton"/></main>

  return (
    <main className={`app ${privacy ? 'privacy' : ''}`}>
      <section className="balanceHeader" aria-labelledby="balance-title"><div><div className="todayLabel">{todayLabel()}</div><div className="balanceLabel" id="balance-title">Общий баланс</div><strong className="balanceValue sensitive">{hidden(summary.net_worth)}</strong></div><button className={`iconButton privacyButton ${privacy ? 'selected' : ''}`} onClick={() => setPrivacy((value) => !value)} aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'} aria-pressed={privacy}>◎</button></section>
      {error && <div className="notice" role="alert">{error}</div>}

      <section className="hero compactHero" aria-labelledby="month-result-title"><div className="heroOrb heroOrbOne"/><div className="heroOrb heroOrbTwo"/><span className="heroMonth">{monthLabel(dashboard?.period?.date_from)}</span><div className="heroMetricRow"><div className="heroMetric resultMetric"><span id="month-result-title">Сальдо</span><strong className="sensitive">{hidden(summary.result_month)}</strong></div><div className="heroMetric incomeMetric"><span><Glyph>↑</Glyph>Доход</span><strong className="sensitive">{hidden(summary.income_month)}</strong></div><div className="heroMetric expenseMetric"><span><Glyph>↓</Glyph>Расход</span><strong className="sensitive">{hidden(summary.expenses_month)}</strong></div></div></section>

      <section className="section balanceBreakdownSection noSectionTitle">
        {currencyGroups.length ? <div className="currencyDistribution">
          <button type="button" className="currencyStackButton compactStackButton" onClick={() => setCurrencyBreakdownOpen((value) => !value)} aria-expanded={currencyBreakdownOpen} aria-controls="currency-breakdown">
            <span className={`hierarchyChevron ${currencyBreakdownOpen ? 'expanded' : ''}`} aria-hidden="true">›</span>
            <span className="currencyStackContent"><span className="currencyStackBar" aria-label="Распределение баланса по валютам">{currencyGroups.map((group, index) => { const width = currencyDistributionTotal > 0 ? Math.abs(group.totalBase) / currencyDistributionTotal * 100 : 100 / currencyGroups.length; return <i key={group.currency} className="currencyStackSegment" style={{ width: `${width}%`, background: segmentColors[index % segmentColors.length] }} /> })}</span><span className="stackCaption" title={currencyCaption}>{currencyCaption}<span className="stackCount"> ({currencyGroups.length})</span></span></span>
          </button>
          {currencyBreakdownOpen && <div className="currencyHierarchy" id="currency-breakdown">{currencyGroups.map((group) => { const expanded = expandedCurrencies.has(group.currency); return <section className="currencyGroup" key={group.currency}><button type="button" className="hierarchyToggle currencyGroupHeader" onClick={() => toggleSetItem(setExpandedCurrencies, group.currency)} aria-expanded={expanded}><span className={`hierarchyChevron ${expanded ? 'expanded' : ''}`} aria-hidden="true">›</span><span className="currencyBadge">{group.currency}</span><span className="hierarchyCount">{group.accounts.length} сч.</span><strong className="sensitive">{hidden(group.total, group.currency)}</strong></button>{expanded && <div className="currencyGroupChildren">{group.accounts.map((account) => <article className="currencyAccountRow" key={account.id}><span>{account.name}</span><strong className="sensitive">{hidden(account.balance_original ?? account.balance_base, group.currency)}</strong></article>)}</div>}</section> })}</div>}
        </div> : <div className="emptyCard">Нет ненулевых валютных остатков</div>}
      </section>

      <section className="section accountsSection compactSectionStart">
        <div className="sectionHeader currencyBalancesHeader"><h2>Баланс по валютам</h2></div>
        {primaryAccount && <article className="primaryAccountCard"><div><span>Основной счёт · {baseCurrency}</span><strong>{primaryAccount.account.name}</strong></div><strong className="sensitive">{hidden(primaryAccount.amountBase, baseCurrency)}</strong></article>}
        <div className="sectionHeader accountsSectionHeader"><h2>Баланс по счетам</h2></div>
        {accountHierarchy.length ? <div className="accountDistribution">
          <button type="button" className="accountStackButton compactStackButton" onClick={() => setAccountBreakdownOpen((value) => !value)} aria-expanded={accountBreakdownOpen} aria-controls="account-breakdown">
            <span className={`hierarchyChevron ${accountBreakdownOpen ? 'expanded' : ''}`} aria-hidden="true">›</span>
            <span className="accountStackContent"><span className="accountStackBar" aria-label="Распределение баланса по счетам">{accountHierarchy.map((node, index) => { const width = accountDistributionTotal > 0 ? Math.abs(node.totalBase) / accountDistributionTotal * 100 : 100 / accountHierarchy.length; return <i key={node.account.id} className="accountStackSegment" style={{ width: `${width}%`, background: segmentColors[index % segmentColors.length] }} /> })}</span><span ref={accountCaptionMetaRef} className="accountStackMeta" title={accountCaption}><span ref={accountCaptionRef} className="accountStackNames">{accountCaption}</span>{accountCaptionOverflow && <span className="stackCount">({accountHierarchy.length})</span>}</span></span>
          </button>
          {accountBreakdownOpen && <div className="accountTree" id="account-breakdown">{accountHierarchy.map((node) => renderAccountNode(node))}</div>}
        </div> : <div className="emptyCard">Нет счетов с остатком от 1</div>}
      </section>

      <section className="section transactionsSection"><div className="sectionHeader"><h2>Последние операции</h2></div><div className="transactionPanel">{transactionGroups.map(([date, items]) => <div className="transactionGroup" key={date}><div className="dateLabel">{dayLabel(date)}</div>{items.map((tx) => { const income = tx.transaction_type === 'income'; return <article className="transaction" key={tx.id}><div className={`transactionIcon ${income ? 'income' : 'expense'}`}>{income ? '↑' : '↓'}</div><div className="transactionBody"><strong>{tx.description || tx.account_name || 'Операция'}</strong><span>{tx.account_name || 'Счёт'}</span></div><div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>{privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || baseCurrency)}`}</div></article>})}</div>)}{!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}</div></section>

      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}><div className="fabActions" aria-hidden={!actionsOpen}><button type="button" className="fabAction"><span>Фото</span><Glyph>▣</Glyph></button><button type="button" className="fabAction"><span>Голос</span><Glyph>●</Glyph></button><button type="button" className="fabAction"><span>Текст</span><Glyph>✎</Glyph></button></div><button type="button" className="fab" onClick={() => setActionsOpen((value) => !value)} aria-label={actionsOpen ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button></div>
      <LabBottomNavigation items={navigationItems} activeId="home" />
    </main>
  )
}

export default App
