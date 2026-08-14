import { useEffect, useMemo, useState } from 'react'
import { createAccount, getTransactionReference } from './api.js'
import { hierarchyOptions } from './hierarchy-options.js'
import { accountTypeOptions, currencyOptions as buildCurrencyOptions } from './reference-options.js'
import { SmartSelect } from './SmartSelect.jsx'

const accountId = (account) => account?.id ?? account?.account_id
const accountParentId = (account) => account?.parent_id ?? account?.parent_account_id ?? account?.account_parent_id ?? null

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
  const [referenceCurrencies, setReferenceCurrencies] = useState([])
  const [referenceLoading, setReferenceLoading] = useState(true)

  useEffect(() => {
    let alive = true
    getTransactionReference()
      .then((refs) => {
        if (!alive) return
        setReferenceCurrencies(refs?.currencies || [])
      })
      .catch(() => {})
      .finally(() => alive && setReferenceLoading(false))
    return () => { alive = false }
  }, [])

  const [name, setName] = useState('')
  const [accountType, setAccountType] = useState('cash')
  const [currencyCode, setCurrencyCode] = useState(String(baseCurrency || 'EUR').toUpperCase())
  const [parentId, setParentId] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const parentOptions = useMemo(() => [
    { value: '', label: 'Без родителя', secondary: 'Верхний уровень', depth: 0 },
    ...hierarchyOptions(accounts, {
      id: accountId,
      parent: accountParentId,
      children: (item) => item?.children || item?.accounts || [],
      label: (item) => item?.name || 'Счёт',
      secondary: (item) => String(item?.currency_code || '').toUpperCase(),
    }),
  ], [accounts])

  const typeOptions = useMemo(() => accountTypeOptions(accountType), [accountType])
  const usedCurrencies = useMemo(
    () => flatAccounts.map((item) => item.currency_code).filter(Boolean),
    [flatAccounts],
  )
  const currencyOptions = useMemo(
    () => buildCurrencyOptions(referenceCurrencies, usedCurrencies, currencyCode),
    [currencyCode, referenceCurrencies, usedCurrencies],
  )

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
        <SmartSelect label="Тип" title="Тип счёта" value={accountType} options={typeOptions} onChange={setAccountType} />
        <SmartSelect label="Валюта" title="Валюта счёта" value={currencyCode} options={currencyOptions} onChange={setCurrencyCode} disabled={referenceLoading && currencyOptions.length === 0} />
        <SmartSelect label="Родитель" title="Расположение счёта" value={parentId} options={parentOptions} onChange={setParentId} />
        {error && <div className="explorerInlineError" role="alert">{error}</div>}
        <button className="accountSheetPrimary" type="submit" disabled={saving || !name.trim()}>{saving ? 'Сохранение…' : 'Добавить счёт'}</button>
      </form>
    </div>
  )
}
