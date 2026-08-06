import { useEffect, useMemo, useState } from 'react'
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

function Glyph({ children }) {
  return <span className="glyph" aria-hidden="true">{children}</span>
}

function App() {
  const [dashboard, setDashboard] = useState(null)
  const [accounts, setAccounts] = useState([])
  const [privacy, setPrivacy] = useState(false)
  const [actionsOpen, setActionsOpen] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    window.Telegram?.WebApp?.ready?.()
    window.Telegram?.WebApp?.expand?.()
    const controller = new AbortController()
    Promise.all([getDashboard(controller.signal), getAccounts(controller.signal)])
      .then(([dash, accountData]) => {
        setDashboard(dash)
        setAccounts(accountData?.accounts || accountData?.items || [])
      })
      .catch((reason) => setError(reason.message || 'Не удалось загрузить данные'))
    return () => controller.abort()
  }, [])

  const summary = dashboard?.summary || {}
  const currency = summary.currency || 'EUR'
  const transactions = useMemo(() => dashboard?.latest_operations || [], [dashboard?.latest_operations])
  const hidden = (value, valueCurrency = currency) => privacy ? '••••••' : money(value, valueCurrency)

  const currencyBalances = useMemo(
    () => (dashboard?.balances_by_currency || []).filter((item) => Math.abs(Number(item.balance || 0)) >= 1),
    [dashboard?.balances_by_currency],
  )

  const accountItems = useMemo(
    () => accounts.filter((account) => Math.abs(Number(account.balance_original ?? account.balance_base ?? 0)) >= 1),
    [accounts],
  )

  const dailyBars = useMemo(() => {
    const grouped = new Map()
    transactions.forEach((transaction) => {
      const key = String(transaction.transaction_date || '').slice(0, 10)
      if (!key) return
      const current = grouped.get(key) || { date: key, income: 0, expense: 0 }
      const amount = Math.abs(Number(transaction.amount_original || 0))
      if (transaction.transaction_type === 'income') current.income += amount
      if (transaction.transaction_type === 'expense') current.expense += amount
      grouped.set(key, current)
    })
    return [...grouped.values()].sort((a, b) => a.date.localeCompare(b.date)).slice(-10)
  }, [transactions])

  const chartMax = useMemo(
    () => Math.max(1, ...dailyBars.flatMap((item) => [item.income, item.expense])),
    [dailyBars],
  )

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

  if (!dashboard && !error) {
    return <main className="app loadingState" aria-busy="true"><div className="skeleton topSkeleton"/><div className="skeleton heroSkeleton"/><div className="skeleton cardSkeleton"/></main>
  }

  return (
    <main className={`app ${privacy ? 'privacy' : ''}`}>
      <section className="balanceHeader" aria-labelledby="balance-title">
        <div>
          <div className="todayLabel">{todayLabel()}</div>
          <div className="balanceLabel" id="balance-title">Общий баланс</div>
          <strong className="balanceValue sensitive">{hidden(summary.net_worth)}</strong>
        </div>
        <button className={`iconButton privacyButton ${privacy ? 'selected' : ''}`} onClick={() => setPrivacy((value) => !value)} aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'} aria-pressed={privacy}>◎</button>
      </section>

      {error && <div className="notice" role="alert">{error}</div>}

      <section className="hero compactHero" aria-labelledby="month-result-title">
        <div className="heroOrb heroOrbOne"/><div className="heroOrb heroOrbTwo"/>
        <div className="compactHeroSummary">
          <div>
            <span className="heroMonth">{monthLabel(dashboard?.period?.date_from)}</span>
            <div className="heroLabel" id="month-result-title">Сальдо месяца</div>
            <div className="heroValue sensitive">{hidden(summary.result_month)}</div>
          </div>
          <div className="dailyChart" aria-label="Подневная диаграмма последних операций">
            {dailyBars.map((item) => (
              <div className="dailyBar" key={item.date} title={dayLabel(item.date)}>
                <i className="incomeBar" style={{ height: `${Math.max(3, item.income / chartMax * 34)}px` }} />
                <i className="expenseBar" style={{ height: `${Math.max(3, item.expense / chartMax * 34)}px` }} />
                <span>{new Date(item.date).getDate()}</span>
              </div>
            ))}
            {!dailyBars.length && <span className="chartEmpty">Нет операций</span>}
          </div>
        </div>
        <div className="heroStats compactStats">
          <div className="heroStat"><Glyph>↑</Glyph><span>Доход</span><strong className="sensitive">{hidden(summary.income_month)}</strong></div>
          <div className="heroStat"><Glyph>↓</Glyph><span>Расход</span><strong className="sensitive">{hidden(summary.expenses_month)}</strong></div>
        </div>
      </section>

      <section className="section balanceBreakdownSection">
        <div className="sectionHeader"><h2>Баланс по валютам</h2></div>
        <div className="balanceList">
          {currencyBalances.map((item) => (
            <article className="balanceRow" key={item.currency}>
              <span className="currencyBadge">{item.currency}</span>
              <strong className="sensitive">{hidden(item.balance, item.currency)}</strong>
            </article>
          ))}
          {!currencyBalances.length && <div className="emptyCard">Нет ненулевых валютных остатков</div>}
        </div>
      </section>

      <section className="section accountsSection">
        <div className="sectionHeader"><h2>Баланс по счетам</h2><button className="textButton" type="button">Все счета <span aria-hidden="true">›</span></button></div>
        <div className="accountRail">
          {accountItems.map((account, index) => (
            <article className={`accountCard accountTone${(index % 3) + 1}`} key={account.id}>
              <div className="accountTop"><div className="accountIcon">{account.currency_code || currency}</div><span className="accountType">{account.account_type || 'Счёт'}</span></div>
              <div className="accountName">{account.name}</div>
              <div className="accountBalance sensitive">{hidden(account.balance_original ?? account.balance_base, account.currency_code || currency)}</div>
            </article>
          ))}
          {!accountItems.length && <div className="emptyCard">Нет счетов с остатком от 1</div>}
        </div>
      </section>

      <section className="section transactionsSection">
        <div className="sectionHeader"><div><span className="eyebrow">История</span><h2>Последние операции</h2></div><button className="textButton" type="button">Все <span aria-hidden="true">›</span></button></div>
        <div className="transactionPanel">
          {transactionGroups.map(([date, items]) => <div className="transactionGroup" key={date}><div className="dateLabel">{dayLabel(date)}</div>{items.map((tx) => { const income = tx.transaction_type === 'income'; return <article className="transaction" key={tx.id}><div className={`transactionIcon ${income ? 'income' : 'expense'}`}>{income ? '↑' : '↓'}</div><div className="transactionBody"><strong>{tx.description || tx.account_name || 'Операция'}</strong><span>{tx.account_name || 'Счёт'}</span></div><div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>{privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || currency)}`}</div></article>})}</div>)}
          {!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}
        </div>
      </section>

      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}><div className="fabActions" aria-hidden={!actionsOpen}><button type="button" className="fabAction"><span>Фото</span><Glyph>▣</Glyph></button><button type="button" className="fabAction"><span>Голос</span><Glyph>●</Glyph></button><button type="button" className="fabAction"><span>Текст</span><Glyph>✎</Glyph></button></div><button type="button" className="fab" onClick={() => setActionsOpen((value) => !value)} aria-label={actionsOpen ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button></div>

      <LabBottomNavigation items={navigationItems} activeId="home" />
    </main>
  )
}

export default App
