import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  createTransaction,
  getAccounts,
  getTransactionReference,
  updateTransaction,
} from './api.js'
import { hierarchyOptions } from './hierarchy-options.js'
import { OperationSourceIcon } from './operation-source.jsx'
import { currencyOptions as buildCurrencyOptions } from './reference-options.js'
import { SmartSelect } from './SmartSelect.jsx'
import { useSpace } from './space-context.js'

const idOf = (item) => item?.id ?? item?.account_id
const parentOf = (item) => item?.parent_id ?? item?.parent_account_id ?? item?.account_parent_id ?? null

function isoParts(value) {
  const date = value ? new Date(value) : new Date()
  const safe = Number.isNaN(date.getTime()) ? new Date() : date
  const year = safe.getFullYear()
  const month = String(safe.getMonth() + 1).padStart(2, '0')
  const day = String(safe.getDate()).padStart(2, '0')
  const hour = String(safe.getHours()).padStart(2, '0')
  const minute = String(safe.getMinutes()).padStart(2, '0')
  return { date: `${year}-${month}-${day}`, time: `${hour}:${minute}` }
}

function displayDate(isoDate) {
  const match = String(isoDate || '').match(/^(\d{4})-(\d{2})-(\d{2})$/)
  return match ? `${match[3]}.${match[2]}.${match[1]}` : ''
}

function parseDisplayDate(value) {
  const match = String(value || '').trim().match(/^(\d{2})\.(\d{2})\.(\d{4})$/)
  if (!match) return null
  const day = Number(match[1])
  const month = Number(match[2])
  const year = Number(match[3])
  const date = new Date(year, month - 1, day)
  if (date.getFullYear() !== year || date.getMonth() !== month - 1 || date.getDate() !== day) return null
  return `${String(year).padStart(4, '0')}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`
}

function validTime(value) {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(String(value || '').trim())
}

function localTimestamp(isoDate, time) {
  const date = new Date(`${isoDate}T${time}:00`)
  return Number.isNaN(date.getTime()) ? null : date.toISOString()
}

function requestId() {
  return Date.now() * 1000 + Math.floor(Math.random() * 1000)
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function flatten(items = []) {
  const result = []
  const visit = (item) => {
    if (!item) return
    result.push(item)
    ;(item.children || item.accounts || []).forEach(visit)
  }
  items.forEach(visit)
  return result
}

function showNativePicker(ref) {
  const input = ref.current
  if (!input) return
  try {
    input.focus({ preventScroll: true })
    if (typeof input.showPicker === 'function') input.showPicker()
    else input.click()
  } catch {
    input.click()
  }
}

function CalendarIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M7 3v3M17 3v3M4.5 8.5h15M5.5 5h13a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Z" />
    </svg>
  )
}

function ClockIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="8" />
      <path d="M12 7.5V12l3 2" />
    </svg>
  )
}

export default function TransactionEditor({ operation = {}, mode = 'edit', onClose, onSaved }) {
  const { activeSpace } = useSpace()
  const creating = mode === 'create'
  const repeat = mode === 'repeat'
  const initial = useMemo(
    () => isoParts(creating || repeat ? null : operation.transaction_date),
    [creating, operation.transaction_date, repeat],
  )
  const datePickerRef = useRef(null)
  const timePickerRef = useRef(null)
  const [reference, setReference] = useState({ currencies: [], categories: [], accounts: [] })
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [form, setForm] = useState(() => ({
    transaction_type: operation.transaction_type === 'adjustment'
      ? 'adjustment'
      : operation.transaction_type === 'income' ? 'income' : 'expense',
    amount: Math.abs(Number(operation.amount_original ?? operation.amount ?? 0)) || '',
    currency: String(operation.currency_original || operation.currency || 'EUR').toUpperCase(),
    account_id: String(operation.account_id ?? ''),
    category_id: operation.category_id == null ? '' : String(operation.category_id),
    dateText: displayDate(initial.date),
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

  const categoryOptions = useMemo(() => {
    const flowType = form.transaction_type === 'income' ? 'income' : 'expense'
    const categories = reference.categories.filter((item) => {
      const itemFlow = String(item?.flow_type || '').toLowerCase()
      return !itemFlow || itemFlow === flowType || String(item?.id) === form.category_id
    })
    return [
      { value: '', label: 'Без категории', secondary: 'Не классифицировать', depth: 0 },
      ...hierarchyOptions(categories, {
        id: (item) => item?.id,
        parent: (item) => item?.parent_id ?? item?.parent_category_id ?? null,
        children: (item) => item?.children || item?.categories || [],
        label: (item) => item?.name || item?.code || 'Категория',
        secondary: (item) => item?.code && item?.name && item.code !== item.name ? item.code : '',
      }),
    ]
  }, [form.category_id, form.transaction_type, reference.categories])

  const usedAccountCurrencies = useMemo(
    () => flatten(reference.accounts).map((item) => item?.currency_code).filter(Boolean),
    [reference.accounts],
  )
  const currencyOptions = useMemo(
    () => buildCurrencyOptions(reference.currencies, usedAccountCurrencies, form.currency),
    [form.currency, reference.currencies, usedAccountCurrencies],
  )

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

  const changeType = (value) => setForm((current) => ({ ...current, transaction_type: value, category_id: '' }))

  const changeAccount = (value) => {
    const option = accountOptions.find((item) => String(item.value) === String(value))
    const account = option?.source
    setForm((current) => ({ ...current, account_id: value, currency: account?.currency_code ? String(account.currency_code).toUpperCase() : current.currency }))
  }

  const selectNativeDate = (event) => {
    const value = event.target.value
    if (!value) return
    setForm((current) => ({ ...current, dateText: displayDate(value) }))
  }

  const selectNativeTime = (event) => {
    const value = event.target.value
    if (!value) return
    setForm((current) => ({ ...current, time: value.slice(0, 5) }))
  }

  const submit = async (event) => {
    event.preventDefault()
    if (saving || loading) return
    const amount = Number(form.amount)
    const isoDate = parseDisplayDate(form.dateText)
    const timestamp = isoDate && validTime(form.time) ? localTimestamp(isoDate, form.time) : null
    if (!form.account_id || !Number.isFinite(amount) || amount <= 0 || !timestamp) {
      showError('Заполните счёт, сумму, дату в формате ДД.ММ.ГГГГ и время в формате 24h ЧЧ:ММ.')
      return
    }
    const payload = {
      account_id: Number(form.account_id),
      transaction_type: form.transaction_type,
      amount_original: amount,
      currency_original: form.currency,
      category_id: form.category_id ? Number(form.category_id) : null,
      description: form.description.trim() || null,
      transaction_date: timestamp,
    }
    setSaving(true)
    try {
      if (creating || repeat) await createTransaction({ ...payload, request_id: form.request_id })
      else await updateTransaction(operation.id, payload)
      await onSaved?.()
      onClose?.()
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить операцию')
    } finally {
      setSaving(false)
    }
  }

  const nativeDate = parseDisplayDate(form.dateText) || ''
  const nativeTime = validTime(form.time) ? form.time : ''
  const dialogLabel = creating ? 'Новая операция' : repeat ? 'Повторить операцию' : 'Изменить операцию'
  const headerAction = creating ? 'Добавить' : repeat ? 'Повторить' : 'Изменить'

  return createPortal(
    <div className="transactionEditorBackdrop visible" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose?.()}>
      <form className="transactionEditorSheet" role="dialog" aria-modal="true" aria-label={dialogLabel} onSubmit={submit}>
        <div className="transactionEditorHeader"><OperationSourceIcon operation={operation} kind={creating ? 'manual' : undefined} /><div><span>Операция</span><strong>{headerAction}</strong>{activeSpace && <span className="spaceContextPill transactionEditorSpace" title={activeSpace.name}>{activeSpace.name}</span>}</div><button type="button" className="transactionEditorClose" onClick={onClose}>×</button></div>
        <div className="transactionEditorForm">
          <SmartSelect label="Тип" title="Тип операции" value={form.transaction_type} options={typeOptions} onChange={changeType} />
          <label className="transactionEditorField"><span>Сумма</span><input type="number" inputMode="decimal" step="0.01" value={form.amount} onChange={update('amount')} /></label>
          <SmartSelect label="Счёт" title="Счёт операции" value={form.account_id} options={accountOptions} onChange={changeAccount} placeholder="Выбрать счёт" disabled={loading} />
          <SmartSelect label="Валюта" title="Валюта операции" value={form.currency} options={currencyOptions} onChange={setField('currency')} disabled={loading} />
          <SmartSelect label="Категория" title="Категория операции" value={form.category_id} options={categoryOptions} onChange={setField('category_id')} disabled={loading} />
          <label className="transactionEditorField transactionEditorPickerField"><span>Дата</span><span className="transactionEditorPickerControl"><input className="transactionEditorDisplayInput" type="text" inputMode="numeric" placeholder="ДД.ММ.ГГГГ" value={form.dateText} onChange={update('dateText')} /><button type="button" className="transactionEditorPickerButton" onClick={() => showNativePicker(datePickerRef)} aria-label="Выбрать дату"><CalendarIcon /></button><input ref={datePickerRef} className="transactionEditorNativePicker" type="date" value={nativeDate} onChange={selectNativeDate} tabIndex={-1} aria-hidden="true" /></span></label>
          <label className="transactionEditorField transactionEditorPickerField"><span>Время</span><span className="transactionEditorPickerControl"><input className="transactionEditorDisplayInput" type="text" inputMode="numeric" placeholder="ЧЧ:ММ" maxLength={5} value={form.time} onChange={update('time')} /><button type="button" className="transactionEditorPickerButton" onClick={() => showNativePicker(timePickerRef)} aria-label="Выбрать время"><ClockIcon /></button><input ref={timePickerRef} className="transactionEditorNativePicker" type="time" value={nativeTime} onChange={selectNativeTime} tabIndex={-1} aria-hidden="true" /></span></label>
          <label className="transactionEditorField transactionDescriptionField"><span>Описание</span><input type="text" value={form.description} onChange={update('description')} /></label>
        </div>
        <button type="submit" className="transactionEditorSave" disabled={saving || loading}>{saving ? 'Сохранение…' : creating ? 'Добавить операцию' : 'Сохранить'}</button>
      </form>
    </div>,
    document.body,
  )
}
