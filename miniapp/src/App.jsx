import { useEffect, useMemo, useState } from 'react'
import { getAccounts, getDashboard } from './api.js'

const money = (value, currency = 'EUR') => new Intl.NumberFormat('ru-RU', {
  style: 'currency', currency, maximumFractionDigits: 0,
}).format(Number(value || 0))

const monthLabel = (date) => new Intl.DateTimeFormat('ru-RU', { month: 'long', year: 'numeric' })
  .format(date ? new Date(date) : new Date())

const dayLabel = (date) => new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' })
  .format(new Date(date))

function Glyph({ children, className = '' }) {
  return <span className={`glyph ${className}`} aria-hidden="true">{children}</span>
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

  if (!dashboard && !error) {
    return (
      <main className="app loadingState" aria-busy="true">
        <div className="skeleton topSkeleton" />
        <div className="skeleton heroSkeleton" />
        <div className="skeleton cardSkeleton" />
      </main>
    )
  }

  return (
    <main className={`app ${privacy ? 'privacy' : ''}`}>
      <div className="ambient ambientOne" />
      <div className="ambient ambientTwo" />

      <header className="topbar">
        <div>
          <div className="brandline"><span className="brandMark">M</span><span>MoneyTrack</span></div>
          <h1>Мои финансы</h1>
        </div>
        <button
          className={`iconButton privacyButton ${privacy ? 'selected' : ''}`}
          onClick={() => setPrivacy((value) => !value)}
          aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'}
          aria-pressed={privacy}
        >
          <span aria-hidden="true">{privacy ? '◉' : '◎'}</span>
        </button>
      </header>

      {error && <div className="notice" role="alert">{error}</div>}

      <section className="hero" aria-labelledby="month-result-title">
        <div className="heroOrb heroOrbOne" />
        <div className="heroOrb heroOrbTwo" />
        <div className="heroTop">
          <div>
            <span className="heroKicker">Финансовый результат</span>
            <span className="heroMonth">{monthLabel(dashboard?.period?.date_from)}</span>
          </div>
          <span className={`trend ${resultPositive ? 'up' : 'down'}`}>
            <span aria-hidden="true">{resultPositive ? '↗' : '↘'}</span>
            {resultPositive ? 'Плюс' : 'Минус'}
          </span>
        </div>
        <div className="heroValueRow">
          <div>
            <div className="heroLabel" id="month-result-title">Сальдо месяца</div>
            <div className="heroValue sensitive" aria-live="polite">{hidden(summary.result_month)}</div>
          </div>
          <div className="sparkline" aria-hidden="true"><i /><i /><i /><i /><i /><i /></div>
        </div>
        <div className="heroStats">
          <div className="heroStat incomeStat">
            <Glyph>↓</Glyph>
            <span>Доход</span>
            <strong className="sensitive">{hidden(summary.income_month)}</strong>
          </div>
          <div className="heroStat expenseStat">
            <Glyph>↑</Glyph>
            <span>Расход</span>
            <strong className="sensitive">{hidden(summary.expenses_month)}</strong>
          </div>
        </div>
      </section>

      <section className="netWorthCard section" aria-labelledby="net-worth-title">
        <div>
          <span className="eyebrow">Капитал</span>
          <h2 id="net-worth-title">Общий баланс</h2>
          <p>Все активные счета</p>
        </div>
        <strong className="netWorthValue sensitive">{hidden(summary.net_worth)}</strong>
      </section>

      <section className="section accountsSection">
        <div className="sectionHeader">
          <div><span className="eyebrow">Деньги</span><h2>Счета</h2></div>
          <button className="textButton" type="button">Все счета <span aria-hidden="true">›</span></button>
        </div>
        <div className="accountRail">
          {accountItems.map((account, index) => (
            <article className={`accountCard accountTone${(index % 3) + 1}`} key={account.id}>
              <div className="accountTop">
                <div className="accountIcon">{account.currency_code || currency}</div>
                <span className="accountType">{account.account_type || 'Счёт'}</span>
              </div>
              <div className="accountName">{account.name}</div>
              <div className="accountBalance sensitive">
                {privacy ? '••••' : money(account.balance_original ?? account.balance_base, account.currency_code || currency)}
              </div>
            </article>
          ))}
          {!accountItems.length && <div className="emptyCard">Счета появятся после загрузки данных</div>}
        </div>
      </section>

      <section className="section transactionsSection">
        <div className="sectionHeader">
          <div><span className="eyebrow">История</span><h2>Последние операции</h2></div>
          <button className="textButton" type="button">Все <span aria-hidden="true">›</span></button>
        </div>
        <div className="transactionPanel">
          {transactionGroups.map(([date, items]) => (
            <div className="transactionGroup" key={date}>
              <div className="dateLabel">{dayLabel(date)}</div>
              {items.map((tx) => {
                const income = tx.transaction_type === 'income'
                return (
                  <article className="transaction" key={tx.id}>
                    <div className={`transactionIcon ${income ? 'income' : 'expense'}`}>
                      <span aria-hidden="true">{income ? '↓' : '↑'}</span>
                    </div>
                    <div className="transactionBody">
                      <strong>{tx.description || tx.account_name || 'Операция'}</strong>
                      <span>{tx.account_name || 'Счёт'}</span>
                    </div>
                    <div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>
                      {privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || currency)}`}
                    </div>
                  </article>
                )
              })}
            </div>
          ))}
          {!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}
        </div>
      </section>

      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}>
        <div className="fabActions" aria-hidden={!actionsOpen}>
          <button type="button" className="fabAction"><span>Фото</span><Glyph>▣</Glyph></button>
          <button type="button" className="fabAction"><span>Голос</span><Glyph>●</Glyph></button>
          <button type="button" className="fabAction"><span>Текст</span><Glyph>✎</Glyph></button>
        </div>
        <button
          type="button"
          className="fab"
          onClick={() => setActionsOpen((value) => !value)}
          aria-label={actionsOpen ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'}
          aria-expanded={actionsOpen}
        >
          <span aria-hidden="true">{actionsOpen ? '×' : '+'}</span>
        </button>
      </div>

      <nav className="bottomNav" aria-label="Основная навигация">
        <button type="button" className="active"><span aria-hidden="true">⌂</span>Главная</button>
        <button type="button"><span aria-hidden="true">▤</span>Операции</button>
        <button type="button"><span aria-hidden="true">◫</span>Счета</button>
        <button type="button"><span aria-hidden="true">⚙</span>Настройки</button>
      </nav>
    </main>
  )
}

export default App
