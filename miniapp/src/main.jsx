import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'
import QuickOperationPortal from './QuickOperationPortal.jsx'
import SettingsPortal from './SettingsPortal.jsx'
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
import './telegram-gesture-policy.js'
import './account-drag-ghost-runtime.js'
import './quick-actions-runtime.js'
import './ux022r3-reference-runtime.js'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
    <QuickOperationPortal />
    <SettingsPortal />
  </StrictMode>,
)
