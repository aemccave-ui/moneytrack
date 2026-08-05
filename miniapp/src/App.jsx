import { useEffect, useMemo, useState } from 'react'
import { getAccounts, getDashboard } from './api.js'

const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency', currency, maximumFractionDigits: 0,
}).format(Number(value || 0))

const monthLabel = (date) => new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric' })
  .format(date ? new Date(date) : new Date())

function Icon({ children }) {
  return <span className="icon" aria-hidden="true">{children}</span>
}

function App() {
  const [dashboard, setDashboard] = useState(null)
  const [accounts, setAccounts] = useState([])
  const [privacy, setPrivacy] = useState(false)
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
  const transactions = dashboard?.latest_operations || []
  const resultPositive = Number(summary.result_month || 0) >= 0
  const accountItems = useMemo(() => accounts.slice(0, 4), [accounts])
  const hidden = (value) => privacy ? '••••••' : money(value, currency)

  if (!dashboard && !error) return <div className="app"><div className="skeleton heroSkeleton" /><div className="skeleton cardSkeleton" /></div>

  return (
    <main className={`app ${privacy ? 'privacy' : ''}`}>
      <header className="topbar">
        <div><div className="eyebrow">MoneyTrack</div><h1>Мои финансы</h1></div>
        <button className="iconButton" onClick={() => setPrivacy((v) => !v)} aria-label="Переключить режим приватности">{privacy ? '◉' : '◎'}</button>
      </header>

      {error && <div className="notice">{error}</div>}

      <section className="hero">
        <div className="heroGlow" />
        <div className="heroTop"><span>{monthLabel(dashboard?.period?.date_from)}</span><span className={`trend ${resultPositive ? 'up' : 'down'}`}>{resultPositive ? '↗' : '↘'} месяц</span></div>
        <div className="heroLabel">Результат месяца</div>
        <div className="heroValue sensitive">{hidden(summary.result_month)}</div>
        <div className="heroStats">
          <div><span>Доход</span><strong className="sensitive">{hidden(summary.income_month)}</strong></div>
          <div><span>Расход</span><strong className="sensitive">{hidden(summary.expenses_month)}</strong></div>
        </div>
      </section>

      <section className="section">
        <div className="sectionTitle"><div><span className="eyebrow">Капитал</span><h2>Общий баланс</h2></div><strong className="sectionAmount sensitive">{hidden(summary.net_worth)}</strong></div>
      </section>

      <section className="quickActions" aria-label="Быстрое добавление">
        <button><Icon>▣</Icon><span>Фото</span></button>
        <button><Icon>◉</Icon><span>Голос</span></button>
        <button><Icon>＋</Icon><span>Текст</span></button>
      </section>

      <section className="section">
        <div className="sectionHeader"><h2>Счета</h2><button className="textButton">Все</button></div>
        <div className="accountGrid">
          {accountItems.map((account) => (
            <article className="accountCard" key={account.id}>
              <div className="accountIcon">{account.currency_code || currency}</div>
              <div className="accountName">{account.name}</div>
              <div className="accountBalance sensitive">{privacy ? '••••' : money(account.balance_original ?? account.balance_base, account.currency_code || currency)}</div>
            </article>
          ))}
          {!accountItems.length && <div className="emptyCard">Счета появятся после загрузки данных</div>}
        </div>
      </section>

      <section className="section transactionsSection">
        <div className="sectionHeader"><h2>Последние операции</h2><button className="textButton">Все</button></div>
        <div className="transactionList">
          {transactions.map((tx) => {
            const income = tx.transaction_type === 'income'
            return <article className="transaction" key={tx.id}>
              <div className={`transactionIcon ${income ? 'income' : 'expense'}`}>{income ? '↙' : '↗'}</div>
              <div className="transactionBody"><strong>{tx.description || tx.account_name || 'Операция'}</strong><span>{tx.account_name || 'Счёт'}</span></div>
              <div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>{privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || currency)}`}</div>
            </article>
          })}
          {!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}
        </div>
      </section>

      <nav className="bottomNav" aria-label="Основная навигация">
        <button className="active"><span>⌂</span>Главная</button><button><span>▤</span>Операции</button><button><span>◫</span>Счета</button><button><span>⚙</span>Настройки</button>
      </nav>
    </main>
  )
}

export default App
