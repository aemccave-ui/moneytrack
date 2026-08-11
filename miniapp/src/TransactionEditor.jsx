import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  createTransaction,
  getAccounts,
  getTransactionReference,
  updateTransaction,
} from './api.js'
import { hierarchyOptions } from './hierarchy-options.js'
import { SmartSelect } from './SmartSelect.jsx'

const idOf = (item) => item?.id ?? item?.account_id
const parentOf = (item) => item?.parent_id ?? item?.parent_account_id ?? item?.account_parent_id ?? null

function isoParts(value) {
  const date = value ? new Date(value) : new Date()
  const safe = Number.isNaN(date.getTime()) ? new Date() : date
  const offset = safe.getTimezoneOffset() * 60000
  const local = new Date(safe.getTime() - offset).toISOString()
  return { date: local.slice(0, 10), time: local.slice(11, 16) }
}

function requestId() {
  return Date.now() * 1000 + Math.floor(Math.random() * 1000)
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function currencyName(code) {
  try {
    return new Intl.DisplayNames(['ru'], { type: 'currency' }).of(code) || code
  } catch {
    return code
  }
}

export default function TransactionEditor({ operation, mode, onClose, onSaved }) {
  const repeat = mode === 'repeat'
  const initial = useMemo(() => isoParts(repeat ? null : operation.transaction_date), [operation.transaction_date, repeat])
  const [reference, setReference] = useState({ currencies: [], categories: [], accounts: [] })
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [form, setForm] = useState(() => ({
    transaction_type: operation.transaction_type === 'adjustment' ? 'adjustment' : operation.transaction_type === 'income' ? 'income' : 'expense',
    amount: Math.abs(Number(operation.amount_original ?? operation.amount ?? 0)) || '',
    currency: String(operation.currency_original || operation.currency || 'EUR').toUpperCase(),
    account_id: String(operation.account_id ?? ''),
    category_id: operation.category_id == null ? '' : String(operation.category_id),
    date: initial.date,
    time: initial.time,
    description: operation.description || '',
    request_id: requestId(),
  }))

  useEffect(() => {
    const controller = new AbortController()
    Promise.all([getTransactionReference(controller.signal), getAccounts(controller.signal)])
      .then(([refs, accountData]) => {
        setReference({
          currencies: refs?.currencies || [],
          categories: refs?.categories || [],
          accounts: accountData?.accounts || accountData?.items || [],
        })
      })
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить справочники')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [])

  const accountOptions = useMemo(() => hierarchyOptions(reference.accounts, {
    id: idOf,
    parent: parentOf,
    children: (item) => item?.children || item?.accounts || [],
    label: (item) => item?.name || 'Счёт',
    secondary: (item) => String(item?.currency_code || '').toUpperCase(),
    disabled: (_item, children) => children.length > 0,
  }), [reference.accounts])

  const categoryOptions = useMemo(() => [
    { value: '', label: 'Без категории', secondary: 'Не классифицировать', depth: 0 },
    ...hierarchyOptions(reference.categories, {
      id: (item) => item?.id,
      parent: (item) => item?.parent_id ?? item?.parent_category_id ?? null,
      children: (item) => item?.children || item?.categories || [],
      label: (item) => item?.name || item?.code || 'Категория',
      secondary: (item) => item?.code && item?.name && item.code !== item.name ? item.code : '',
    }),
  ], [reference.categories])

  const currencyOptions = useMemo(() => {
    const codes = [...new Set([
      form.currency,
      ...reference.currencies.map((item) => String(item?.code || item || '').toUpperCase()).filter(Boolean),
    ])].filter(Boolean).sort()
    return codes.map((code) => ({ value: code, label: code, secondary: currencyName(code) }))
  }, [form.currency, reference.currencies])

  const typeOptions = [
    { value: 'expense', label: 'Расход' },
    { value: 'income', label: 'Доход' },
    { value: 'adjustment', label: 'Корректировка' },
  ]

  const update = (key) => (event) => {
    const value = event.target.value
    setForm((current) => ({ ...current, [key]: value }))
  }

  const setField = (key) => (value) => setForm((current) => ({ ...current, [key]: value }))

  const changeAccount = (value) => {
    const option = accountOptions.find((item) => String(item.value) === String(value))
    const account = option?.source
    setForm((current) => ({
      ...current,
      account_id: value,
      currency: account?.currency_code ? String(account.currency_code).toUpperCase() : current.currency,
    }))
  }

  const submit = async (event) => {
    event.preventDefault()
    if (saving || loading) return
    const amount = Number(form.amount)
    if (!form.account_id || !Number.isFinite(amount) || amount <= 0 || !form.date || !form.time) {
      showError('Заполните счёт, сумму, дату и время.')
      return
    }
    const payload = {
      account_id: Number(form.account_id),
      transaction_type: form.transaction_type,
      amount_original: amount,
      currency_original: form.currency,
      category_id: form.category_id ? Number(form.category_id) : null,
      description: form.description.trim() || null,
      transaction_date: `${form.date}T${form.time}:00`,
    }
    setSaving(true)
    try {
      if (repeat) {
        await createTransaction({ ...payload, request_id: form.request_id })
      } else {
        await updateTransaction(operation.id, payload)
      }
      await onSaved?.()
      onClose()
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить операцию')
    } finally {
      setSaving(false)
    }
  }

  return createPortal(
    <div className="transactionEditorBackdrop visible" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <form className="transactionEditorSheet" role="dialog" aria-modal="true" aria-label={repeat ? 'Повторить операцию' : 'Изменить операцию'} onSubmit={submit}>
        <div className="transactionEditorHeader"><div><span>{repeat ? 'Новая операция' : 'Операция'}</span><strong>{repeat ? 'Повторить' : 'Изменить'}</strong></div><button type="button" className="transactionEditorClose" onClick={onClose}>×</button></div>
        <div className="transactionEditorForm">
          <SmartSelect label="Тип" title="Тип операции" value={form.transaction_type} options={typeOptions} onChange={setField('transaction_type')} />
          <label className="transactionEditorField"><span>Сумма</span><input type="number" inputMode="decimal" step="0.01" value={form.amount} onChange={update('amount')} /></label>
          <SmartSelect label="Счёт" title="Счёт операции" value={form.account_id} options={accountOptions} onChange={changeAccount} placeholder="Выбрать счёт" disabled={loading} />
          <SmartSelect label="Валюта" title="Валюта операции" value={form.currency} options={currencyOptions} onChange={setField('currency')} disabled={loading} />
          <SmartSelect label="Категория" title="Категория операции" value={form.category_id} options={categoryOptions} onChange={setField('category_id')} disabled={loading} />
          <label className="transactionEditorField"><span>Дата</span><input type="date" value={form.date} onChange={update('date')} /></label>
          <label className="transactionEditorField"><span>Время</span><input type="time" value={form.time} onChange={update('time')} /></label>
          <label className="transactionEditorField transactionDescriptionField"><span>Описание</span><input type="text" value={form.description} onChange={update('description')} /></label>
        </div>
        <button type="submit" className="transactionEditorSave" disabled={saving || loading}>{saving ? 'Сохранение…' : 'Сохранить'}</button>
      </form>
    </div>,
    document.body,
  )
}
