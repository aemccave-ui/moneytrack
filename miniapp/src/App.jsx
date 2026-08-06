import { useEffect, useMemo, useState } from 'react'
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

function NavIcon({ name }) {
  const common = { viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.9, strokeLinecap: 'round', strokeLinejoin: 'round', 'aria-hidden': true }
  if (name === 'home') return <svg {...common}><path d="M3 10.8 12 3l9 7.8"/><path d="M5 9.8V21h14V9.8"/><path d="M9 21v-6h6v6"/></svg>
  if (name === 'accounts') return <svg {...common}><rect x="3" y="5" width="18" height="14" rx="3"/><path d="M3 9h18"/><path d="M7 15h3"/></svg>
  if (name === 'budgets') return <svg {...common}><path d="M12 3a9 9 0 1 0 9 9h-9z"/><path d="M12 3v9h9"/></svg>
  if (name === 'stats') return <svg {...common}><path d="M5 20V11"/><path d="M12 20V4"/><path d="M19 20v-7"/></svg>
  return <svg {...common}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.12 2.12-.06-.06A1.7 1.7 0 0 0 15.74 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.38 1.08V21h-3v-.08A1.7 1.7 0 0 0 10.26 19.4a1.7 1.7 0 0 0-1.88-.34l-.06.06-2.12-2.12.06-.06A1.7 1.7 0 0 0 6.6 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.08-.38H5v-3h.08A1.7 1.7 0 0 0 6.6 9a1.7 1.7 0 0 0-.34-1.88l-.06-.06 2.12-2.12.06.06A1.7 1.7 0 0 0 10.26 4.6a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .38-1.08V3h3v.08A1.7 1.7 0 0 0 15.74 4.6a1.7 1.7 0 0 0 1.88.34l.06-.06 2.12 2.12-.06.06A1.7 1.7 0 0 0 19.4 9c.4.28.74.62 1 1 .22.33.35.7.38 1.08V11h.08v3h-.08A1.7 1.7 0 0 0 19.4 15Z"/></svg>
}

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
  const resultPositive = Number(summary.result_month || 0) >= 0
  const accountItems = useMemo(() => accounts.slice(0, 4), [accounts])
  const hidden = (value) => privacy ? '••••••' : money(value, currency)

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

  if (!dashboard && !error) return <main className="app loadingState" aria-busy="true"><div className="skeleton topSkeleton"/><div className="skeleton heroSkeleton"/><div className="skeleton cardSkeleton"/></main>

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

      <section className="hero" aria-labelledby="month-result-title">
        <div className="heroOrb heroOrbOne"/><div className="heroOrb heroOrbTwo"/>
        <div className="heroTop"><div><span className="heroKicker">Финансовый результат</span><span className="heroMonth">{monthLabel(dashboard?.period?.date_from)}</span></div><span className={`trend ${resultPositive ? 'up' : 'down'}`}>{resultPositive ? '↗ Плюс' : '↘ Минус'}</span></div>
        <div className="heroValueRow"><div><div className="heroLabel" id="month-result-title">Сальдо месяца</div><div className="heroValue sensitive">{hidden(summary.result_month)}</div></div><div className="sparkline" aria-hidden="true"><i/><i/><i/><i/><i/><i/></div></div>
        <div className="heroStats"><div className="heroStat"><Glyph>↓</Glyph><span>Доход</span><strong className="sensitive">{hidden(summary.income_month)}</strong></div><div className="heroStat"><Glyph>↑</Glyph><span>Расход</span><strong className="sensitive">{hidden(summary.expenses_month)}</strong></div></div>
      </section>

      <section className="section accountsSection">
        <div className="sectionHeader"><div><span className="eyebrow">Деньги</span><h2>Счета</h2></div><button className="textButton" type="button">Все счета <span aria-hidden="true">›</span></button></div>
        <div className="accountRail">
          {accountItems.map((account, index) => <article className={`accountCard accountTone${(index % 3) + 1}`} key={account.id}><div className="accountTop"><div className="accountIcon">{account.currency_code || currency}</div><span className="accountType">{account.account_type || 'Счёт'}</span></div><div className="accountName">{account.name}</div><div className="accountBalance sensitive">{privacy ? '••••' : money(account.balance_original ?? account.balance_base, account.currency_code || currency)}</div></article>)}
          {!accountItems.length && <div className="emptyCard">Счета появятся после загрузки данных</div>}
        </div>
      </section>

      <section className="section transactionsSection">
        <div className="sectionHeader"><div><span className="eyebrow">История</span><h2>Последние операции</h2></div><button className="textButton" type="button">Все <span aria-hidden="true">›</span></button></div>
        <div className="transactionPanel">{transactionGroups.map(([date, items]) => <div className="transactionGroup" key={date}><div className="dateLabel">{dayLabel(date)}</div>{items.map((tx) => { const income = tx.transaction_type === 'income'; return <article className="transaction" key={tx.id}><div className={`transactionIcon ${income ? 'income' : 'expense'}`}>{income ? '↓' : '↑'}</div><div className="transactionBody"><strong>{tx.description || tx.account_name || 'Операция'}</strong><span>{tx.account_name || 'Счёт'}</span></div><div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>{privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || currency)}`}</div></article>})}</div>)}{!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}</div>
      </section>

      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}><div className="fabActions" aria-hidden={!actionsOpen}><button type="button" className="fabAction"><span>Фото</span><Glyph>▣</Glyph></button><button type="button" className="fabAction"><span>Голос</span><Glyph>●</Glyph></button><button type="button" className="fabAction"><span>Текст</span><Glyph>✎</Glyph></button></div><button type="button" className="fab" onClick={() => setActionsOpen((value) => !value)} aria-label={actionsOpen ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button></div>

      <nav className="bottomNav" aria-label="Основная навигация">
        {[['home','Главная'],['accounts','Счета'],['budgets','Бюджеты'],['stats','Статистика'],['settings','Настройки']].map(([icon,label], index) => <button type="button" className={index === 0 ? 'active' : ''} key={label}><NavIcon name={icon}/><span>{label}</span></button>)}
      </nav>
    </main>
  )
}

export default App
