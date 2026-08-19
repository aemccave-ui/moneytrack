import { LabBottomNavigation } from '../../packages/lab-design-system/navigation.jsx'
import AccountCreateSheet from '../AccountCreateSheet.jsx'
import AccountsExplorer from '../AccountsExplorer.jsx'

export default function AccountsScreen({
  accounts,
  baseCurrency,
  privacy,
  onPrivacyToggle,
  initialAccountId,
  onAccountsChanged,
  actionsOpen,
  onToggleActions,
  accountCreateOpen,
  onOpenAccountCreate,
  onCloseAccountCreate,
  navigation,
}) {
  return (
    <main key="accounts" className={`app ${privacy ? 'privacy' : ''}`}>
      <AccountsExplorer
        accounts={accounts}
        baseCurrency={baseCurrency}
        privacy={privacy}
        onPrivacyToggle={onPrivacyToggle}
        initialAccountId={initialAccountId}
        onAccountsChanged={onAccountsChanged}
      />
      <div className={`fabMenu ${actionsOpen ? 'open' : ''}`}>
        <div className="fabActions" aria-hidden={!actionsOpen}>
          <button type="button" className="fabAction" onClick={onOpenAccountCreate}><span>Счёт</span><b className="glyph" aria-hidden="true">▤</b></button>
        </div>
        <button type="button" className="fab" onClick={onToggleActions} aria-label={actionsOpen ? 'Закрыть добавление счёта' : 'Открыть добавление счёта'} aria-expanded={actionsOpen}><span aria-hidden="true">{actionsOpen ? '×' : '+'}</span></button>
      </div>
      {accountCreateOpen && <AccountCreateSheet accounts={accounts} baseCurrency={baseCurrency} onClose={onCloseAccountCreate} onSaved={onAccountsChanged} />}
      <LabBottomNavigation items={navigation} activeId="accounts" />
    </main>
  )
}
