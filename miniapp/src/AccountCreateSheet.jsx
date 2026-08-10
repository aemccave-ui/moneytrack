import { useMemo, useState } from 'react'
import { createAccount } from './api.js'

const accountId = (account) => String(account.id ?? account.account_id)

function flattenAccounts(accounts = []) {
  const result = []
  const visit = (account) => {
    if (!account) return
    result.push(account)
    ;(account.children || account.accounts || []).forEach(visit)
  }
  accounts.forEach(visit)
  return result
}

export default function AccountCreateSheet({ accounts, baseCurrency, onClose, onSaved }) {
  const flatAccounts = useMemo(() => flattenAccounts(accounts), [accounts])
  const currencies = useMemo(() => [...new Set([
    String(baseCurrency || 'EUR').toUpperCase(),
    ...flatAccounts.map((item) => String(item.currency_code || '').toUpperCase()).filter(Boolean),
  ])].sort(), [baseCurrency, flatAccounts])
  const accountTypes = useMemo(() => [...new Set([
    'cash',
    ...flatAccounts.map((item) => String(item.account_type || '').trim()).filter(Boolean),
  ])], [flatAccounts])

  const [name, setName] = useState('')
  const [accountType, setAccountType] = useState(accountTypes[0] || 'cash')
  const [currencyCode, setCurrencyCode] = useState(currencies[0] || String(baseCurrency || 'EUR').toUpperCase())
  const [parentId, setParentId] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const submit = async (event) => {
    event.preventDefault()
    const normalizedName = name.trim()
    if (!normalizedName || saving) return
    setSaving(true)
    setError('')
    try {
      await createAccount({
        name: normalizedName,
        code: null,
        accountType,
        currencyCode,
        parentId: parentId || null,
      })
      await onSaved?.()
      onClose?.()
    } catch (reason) {
      setError(reason?.message || 'Не удалось добавить счёт')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="accountSheetBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose?.()}>
      <form className="accountSheet" onSubmit={submit} role="dialog" aria-modal="true" aria-label="Добавить новый счёт">
        <header><strong>Добавить счёт</strong><button type="button" onClick={onClose}>×</button></header>
        <label><span>Название</span><input value={name} onChange={(event) => setName(event.target.value)} autoFocus /></label>
        <label><span>Тип</span><select value={accountType} onChange={(event) => setAccountType(event.target.value)}>{accountTypes.map((type) => <option key={type} value={type}>{type}</option>)}</select></label>
        <label><span>Валюта</span><select value={currencyCode} onChange={(event) => setCurrencyCode(event.target.value)}>{currencies.map((code) => <option key={code} value={code}>{code}</option>)}</select></label>
        <label><span>Родитель</span><select value={parentId} onChange={(event) => setParentId(event.target.value)}><option value="">Без родителя / верхний уровень</option>{flatAccounts.map((item) => <option key={accountId(item)} value={accountId(item)}>{item.name}</option>)}</select></label>
        {error && <div className="explorerInlineError" role="alert">{error}</div>}
        <button className="accountSheetPrimary" type="submit" disabled={saving || !name.trim()}>{saving ? 'Сохранение…' : 'Добавить счёт'}</button>
      </form>
    </div>
  )
}
