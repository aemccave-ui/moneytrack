import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import {
  createTransaction,
  getAccounts,
  getTransactionReference,
  updateTransaction,
} from './api.js'

const idOf = (item) => item?.id ?? item?.account_id
const parentOf = (item) => item?.parent_id ?? item?.parent_account_id ?? null

function flattenAccounts(items = []) {
  const result = []
  const visit = (item, inheritedParent = null) => {
    const normalized = inheritedParent == null || parentOf(item) != null
      ? item
      : { ...item, parent_id: inheritedParent }
    result.push(normalized)
    const id = idOf(item)
    ;(item.children || item.accounts || []).forEach((child) => visit(child, id))
  }
  items.forEach((item) => visit(item))
  return result
}

function flattenCategories(items = []) {
  const result = []
  const visit = (item, depth = 0) => {
    result.push({ ...item, depth })
    ;(item.children || item.categories || []).forEach((child) => visit(child, depth + 1))
  }
  items.forEach((item) => visit(item))
  return result
}

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
          categories: flattenCategories(refs?.categories || []),
          accounts: flattenAccounts(accountData?.accounts || accountData?.items || []),
        })
      })
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить справочники')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [])

  const childParentIds = useMemo(() => new Set(reference.accounts.map(parentOf).filter((id) => id != null).map(String)), [reference.accounts])
  const postingAccounts = reference.accounts.filter((account) => !childParentIds.has(String(idOf(account))))

  const update = (key) => (event) => {
    const value = event.target.value
    setForm((current) => ({ ...current, [key]: value }))
  }

  const changeAccount = (event) => {
    const value = event.target.value
    const account = postingAccounts.find((item) => String(idOf(item)) === String(value))
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
          <label className="transactionEditorField"><span>Тип</span><select value={form.transaction_type} onChange={update('transaction_type')}><option value="expense">Расход</option><option value="income">Доход</option><option value="adjustment">Корректировка</option></select></label>
          <label className="transactionEditorField"><span>Сумма</span><input type="number" inputMode="decimal" step="0.01" value={form.amount} onChange={update('amount')} /></label>
          <label className="transactionEditorField"><span>Счёт</span><select value={form.account_id} onChange={changeAccount} disabled={loading}><option value="">Выбрать</option>{postingAccounts.map((account) => <option key={idOf(account)} value={idOf(account)}>{account.name} · {account.currency_code}</option>)}</select></label>
          <label className="transactionEditorField"><span>Валюта</span><select value={form.currency} onChange={update('currency')} disabled={loading}>{[...new Set([form.currency, ...reference.currencies.map((item) => item.code)])].filter(Boolean).map((code) => <option key={code} value={code}>{code}</option>)}</select></label>
          <label className="transactionEditorField"><span>Категория</span><select value={form.category_id} onChange={update('category_id')} disabled={loading}><option value="">Без категории</option>{reference.categories.map((category) => <option key={category.id} value={category.id}>{'— '.repeat(category.depth || 0)}{category.name || category.code}</option>)}</select></label>
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