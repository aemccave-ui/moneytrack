import { LabBottomNavigation } from '../../packages/lab-design-system/navigation.jsx'
import { BalanceHero } from '../BalanceHero.jsx'
import { RecentOperations } from '../RecentOperations.jsx'
import { localDateKey } from '../date-format.js'

const segmentColors = ['#1d5559', '#4f9fa3', '#79b7b9', '#a4cccd', '#c6dddd', '#799397']
const accountId = (account) => String(account.id ?? account.account_id)

const dayLabel = (date) => new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'long' })
  .format(new Date(`${String(date).slice(0, 10)}T12:00:00`))

const monthLabel = (date) => new Intl.DateTimeFormat('ru-RU', {
  month: 'long',
  year: 'numeric',
})
  .format(new Date(`${String(date).slice(0, 10)}T12:00:00`))
  .replace(/^./, (char) => char.toUpperCase())

const todayLabel = () => new Intl.DateTimeFormat('ru-RU', {
  day: 'numeric', month: 'long', weekday: 'long',
}).format(new Date()).replace(/^./, (char) => char.toUpperCase())

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
          <span className="homeCountBadge accountRowCountBadge" aria-label={`Счетов: ${node.leafCount}`} title={`Счетов: ${node.leafCount}`}>{node.leafCount}</span>
          <span className="accountTreeIdentity">
            <span className="homeAggregateTitleRow"><strong>{node.account.name}</strong></span>
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

export default function HomeScreen({
  privacy,
  onPrivacyToggle,
  error,
  currentNetWorth,
  currentNetWorthCurrency,
  hidden,
  dashboard,
  summary,
  reportCurrency,
  baseCurrency,
  money,
  homeBreakdownReady,
  homeSnapshotError,
  currencyGroups,
  currencyDistributionTotal,
  currencyCaption,
  currencyBreakdownOpen,
  onCurrencyBreakdownToggle,
  expandedCurrencies,
  onToggleCurrency,
  accountHierarchy,
  accountDistributionTotal,
  accountCaption,
  accountBreakdownOpen,
  onAccountBreakdownToggle,
  expandedAccounts,
  onToggleAccount,
  primaryAccount,
  transactionGroups,
  onReloadDashboard,
  actionsOpen,
  onToggleActions,
  navigation,
}) {
  const homeBreakdownFallback = homeSnapshotError
    ? <div className="emptyCard" role="alert">Не удалось загрузить актуальные остатки</div>
    : <div className="emptyCard">Загрузка остатков…</div>

  return (
    <main key="home" className={`app ${privacy ? 'privacy' : ''}`}>
      <section className="balanceHeader" aria-labelledby="balance-title"><div><div className="todayLabel">{todayLabel()}</div><div className="balanceLabel" id="balance-title">Общий баланс</div><strong className="balanceValue sensitive">{hidden(currentNetWorth, currentNetWorthCurrency)}</strong></div><button className={`iconButton privacyButton ${privacy ? 'selected' : ''}`} onClick={onPrivacyToggle} aria-label={privacy ? 'Показать суммы' : 'Скрыть суммы'} aria-pressed={privacy}>◎</button></section>
      {error && <div className="notice" role="alert">{error}</div>}

      <BalanceHero
        label={monthLabel(dashboard?.period?.date_from || localDateKey(new Date()))}
        result={summary.result_month}
        income={summary.income_month}
        expense={summary.expenses_month}
        privacy={privacy}
        baseCurrency={reportCurrency}
        money={money}
      />

      <section className="section balanceBreakdownSection noSectionTitle">
        <div className="sectionHeader currencyBalancesHeader"><h2>Баланс по валютам</h2></div>
        {homeBreakdownReady ? (currencyGroups.length ? <div className="currencyDistribution">
          <button type="button" className="currencyStackButton compactStackButton" onClick={onCurrencyBreakdownToggle} aria-expanded={currencyBreakdownOpen} aria-controls="currency-breakdown">
            <span className={`hierarchyChevron ${currencyBreakdownOpen ? 'expanded' : ''}`} aria-hidden="true">›</span>
            <span className="currencyStackContent"><span className="currencyStackBar" aria-label="Распределение баланса по валютам">{currencyGroups.map((group, index) => { const width = currencyDistributionTotal > 0 ? Math.abs(group.totalBase) / currencyDistributionTotal * 100 : 100 / currencyGroups.length; return <i key={group.currency} className="currencyStackSegment" style={{ width: `${width}%`, background: segmentColors[index % segmentColors.length] }} /> })}</span><HomeNamedSummary title={currencyCaption} items={currencyGroups.map((group) => ({ key: group.currency, label: group.currency, count: group.accounts.length }))} /></span>
          </button>
          {currencyBreakdownOpen && <div className="currencyHierarchy" id="currency-breakdown">{currencyGroups.map((group) => { const expanded = expandedCurrencies.has(group.currency); return <section className="currencyGroup" key={group.currency}><button type="button" className="hierarchyToggle currencyGroupHeader" onClick={() => onToggleCurrency(group.currency)} aria-expanded={expanded}><span className={`hierarchyChevron ${expanded ? 'expanded' : ''}`} aria-hidden="true">›</span><span className="homeNamedAggregate"><span className="homeCountBadge currencyRowCountBadge" aria-label={`Счетов: ${group.accounts.length}`} title={`Счетов: ${group.accounts.length}`}>{group.accounts.length}</span><span className="currencyBadge">{group.currency}</span></span><strong className="sensitive">{hidden(group.total, group.currency)}</strong></button>{expanded && <div className="currencyGroupChildren">{group.accounts.map((account) => <article className="currencyAccountRow" key={accountId(account)}><span className="hierarchyChevron currencyAccountMarker" aria-hidden="true">•</span><span className="accountTreeIdentity"><strong>{account.name}</strong><span>{account.account_type || 'Счёт'} · {group.currency}</span></span><strong className="sensitive">{hidden(account.balance_original ?? 0, group.currency)}</strong></article>)}</div>}</section> })}</div>}
        </div> : <div className="emptyCard">Нет ненулевых валютных остатков</div>) : null}
      </section>

      <section className="section accountsSection compactSectionStart">
        <div className="sectionHeader accountsSectionHeader"><h2>Баланс по счетам</h2></div>
        {homeBreakdownReady ? <>
          {primaryAccount && <article className="primaryAccountCard"><div><span>Основной счёт · {baseCurrency}</span><strong>{primaryAccount.account.name}</strong></div><strong className="sensitive">{hidden(primaryAccount.amountBase, baseCurrency)}</strong></article>}
          {accountHierarchy.length ? <div className="accountDistribution">
            <button type="button" className="accountStackButton compactStackButton" onClick={onAccountBreakdownToggle} aria-expanded={accountBreakdownOpen} aria-controls="account-breakdown">
              <span className={`hierarchyChevron ${accountBreakdownOpen ? 'expanded' : ''}`} aria-hidden="true">›</span>
              <span className="accountStackContent"><span className="accountStackBar" aria-label="Распределение баланса по счетам">{accountHierarchy.map((node, index) => { const width = accountDistributionTotal > 0 ? Math.abs(node.totalBase) / accountDistributionTotal * 100 : 100 / accountHierarchy.length; return <i key={accountId(node.account)} className="accountStackSegment" style={{ width: `${width}%`, background: segmentColors[index % segmentColors.length] }} /> })}</span><HomeNamedSummary title={accountCaption} items={accountHierarchy.map((node) => ({ key: accountId(node.account), label: node.account.name, count: node.leafCount }))} /></span>
            </button>
            {accountBreakdownOpen && <HomeAccountTree hierarchy={accountHierarchy} expanded={expandedAccounts} onToggle={onToggleAccount} baseCurrency={baseCurrency} hidden={hidden} />}
          </div> : <div className="emptyCard">Счета пока не созданы</div>}
        </> : homeBreakdownFallback}
      </section>

      <RecentOperations groups={transactionGroups} transactions={transactionGroups.flatMap(([, items]) => items)} privacy={privacy} baseCurrency={baseCurrency} money={money} dayLabel={dayLabel} onDeleted={onReloadDashboard} />

      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}><div className="fabActions" aria-hidden={!actionsOpen}><button type="button" className="fabAction"><span>Фото</span><b aria-hidden="true">▣</b></button><button type="button" className="fabAction"><span>Голос</span><b aria-hidden="true">●</b></button><button type="button" className="fabAction"><span>Текст</span><b aria-hidden="true">✎</b></button></div><button type="button" className="fab" onClick={onToggleActions} aria-label={actionsOpen ? 'Закрыть быстрое добавление' : 'Открыть быстрое добавление'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button></div>
      <LabBottomNavigation items={navigation} activeId="home" />
    </main>
  )
}
