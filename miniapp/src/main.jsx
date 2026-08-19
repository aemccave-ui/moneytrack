import { StrictMode, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'
import QuickOperationPortal from './QuickOperationPortal.jsx'
import SettingsPortal from './SettingsPortal.jsx'
import SecurityGate from './SecurityGate.jsx'
import SpaceGate from './SpaceGate.jsx'
import '../packages/lab-design-system/navigation.css'
import './styles.css'
import './polish.css'
import './currency-layout.css'
import './account-distribution.css'
import './recent-operations.css'
import './accounts-explorer.css'
import './ux024-home.css'
import './ux022r3-frontend.css'
import './ux022r3-selectors.css'
import './ux022r3-saldo.css'
import './ux022r3-reference-runtime.css'
import './transaction-picker.css'
import './receipt-modal.css'
import './spc001-space.css'
import './spc001-f4-acceptance-polish.css'
import './screens/ux025-screens.css'
import './screens/ux025-settings-page-scroll.css'
import './telegram-gesture-policy.js'
import './account-drag-ghost-runtime.js'
import './quick-actions-runtime.js'
import './ux022r3-reference-runtime.js'

export function ProtectedApplication() {
  const [refreshKey, setRefreshKey] = useState(0)

  useEffect(() => {
    const refresh = () => setRefreshKey((value) => value + 1)
    window.addEventListener('moneytrack:quick-capture-completed', refresh)
    return () => window.removeEventListener('moneytrack:quick-capture-completed', refresh)
  }, [])

  return (
    <SpaceGate key={refreshKey}>
      <App />
      <QuickOperationPortal />
      <SettingsPortal />
    </SpaceGate>
  )
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <SecurityGate>
      <ProtectedApplication />
    </SecurityGate>
  </StrictMode>,
)
