import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'
import '../packages/lab-design-system/navigation.css'
import './styles.css'
import './polish.css'
import './currency-layout.css'
import './account-distribution.css'
import './recent-operations.css'
import './accounts-explorer.css'
import './ux022r3-frontend.css'
import './telegram-gesture-policy.js'
import './currency-summary.js'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
