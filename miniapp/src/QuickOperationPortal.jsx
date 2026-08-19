import { useEffect, useState } from 'react'
import TransactionEditor from './TransactionEditor.jsx'

export default function QuickOperationPortal() {
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const openEditor = () => setOpen(true)
    window.addEventListener('moneytrack:new-operation', openEditor)
    return () => window.removeEventListener('moneytrack:new-operation', openEditor)
  }, [])

  if (!open) return null

  return (
    <TransactionEditor
      operation={{}}
      mode="create"
      onClose={() => setOpen(false)}
      onSaved={() => {
        setOpen(false)
        window.dispatchEvent(new CustomEvent('moneytrack:quick-capture-completed'))
      }}
    />
  )
}
