import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { createTransfer, getAccounts, getTransfer, updateTransfer } from './api.js'
import { hierarchyOptions, SmartSelect } from './SmartSelect.jsx'

const idOf = (item) => item?.id ?? item?.account_id
const parentOf = (item) => item?.parent_id ?? item?.parent_account_id ?? item?.account_parent_id ?? null

function transferIdOf(operation) {
  if (operation?.transfer_id != null) return Number(operation.transfer_id)
  const match = String(operation?.id || '').match(/^transfer-(\d+)$/)
  return match ? Number(match[1]) : null
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

export default function TransferEditor({ operation, mode = 'edit', onClose, onSaved }) {
  const repeat = mode === 'repeat'
  const transferId = transferIdOf(operation)
  const [detail, setDetail] = useState(null)
  const [accounts, setAccounts] = useState([])
  const [form, setForm] = useState(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (!transferId) {
      showError('Не удалось определить перевод.')
      setLoading(false)
      return undefined
    }
    const controller = new AbortController()
    Promise.all([getTransfer(transferId, controller.signal), getAccounts(controller.signal)])
      .then(([payload, accountPayload]) => {
        const row = payload?.transfer || payload
        const parts = isoParts(repeat ? null : row.transfer_date)
        setDetail(row)
        setAccounts(accountPayload?.accounts || accountPayload?.items || [])
        setForm({
          from_account_id: String(row.from_account_id ?? ''),
          to_account_id: String(row.to_account_id ?? ''),
          from_amount: Math.abs(Number(row.from_amount || 0)) || '',
          date: parts.date,
          time: parts.time,
          transfer_type: row.transfer_type || 'transfer',
          request_id: requestId(),
        })
      })
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить перевод')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [repeat, transferId])

  const accountOptions = useMemo(() => hierarchyOptions(accounts, {
    id: idOf,
    parent: parentOf,
    children: (item) => item?.children || item?.accounts || [],
    label: (item) => item?.name || 'Счёт',
    secondary: (item) => String(item?.currency_code || '').toUpperCase(),
    disabled: (_item, children) => children.length > 0,
  }), [accounts])

  const byId = useMemo(() => new Map(accountOptions.map((option) => [String(option.value), option.source])), [accountOptions])
  const fromAccount = form ? byId.get(String(form.from_account_id)) : null
  const toAccount = form ? byId.get(String(form.to_account_id)) : null
  const fromCurrency = String(fromAccount?.currency_code || detail?.from_currency || '').toUpperCase()
  const toCurrency = String(toAccount?.currency_code || detail?.to_currency || '').toUpperCase()
  const sameCurrency = fromCurrency && toCurrency && fromCurrency === toCurrency

  const setField = (key) => (value) => setForm((current) => current ? { ...current, [key]: value } : current)
  const updateInput = (key) => (event) => setField(key)(event.target.value)

  const submit = async (event) => {
    event.preventDefault()
    if (!form || saving || loading) return
    const amount = Number(form.from_amount)
    if (!form.from_account_id || !form.to_account_id || form.from_account_id === form.to_account_id || !Number.isFinite(amount) || amount <= 0) {
      showError('Выберите два разных счёта и укажите сумму.')
      return
    }
    const transferType = sameCurrency
      ? 'transfer'
      : form.transfer_type === 'exchange' ? 'exchange' : 'transferexchange'
    const payload = {
      from_account_id: Number(form.from_account_id),
      to_account_id: Number(form.to_account_id),
      from_amount: amount,
      transfer_date: `${form.date}T${form.time}:00`,
      transfer_type: transferType,
    }
    setSaving(true)
    try {
      if (repeat) await createTransfer({ ...payload, request_id: form.request_id })
      else await updateTransfer(transferId, payload)
      await onSaved?.()
      onClose()
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить перевод')
    } finally {
      setSaving(false)
    }
  }

  return createPortal(
    <div className="transactionEditorBackdrop visible" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <form className="transactionEditorSheet transferEditorSheet" role="dialog" aria-modal="true" aria-label={repeat ? 'Повторить перевод' : 'Изменить перевод'} onSubmit={submit}>
        <div className="transactionEditorHeader"><div><span>{repeat ? 'Новый перевод' : 'Перевод'}</span><strong>{repeat ? 'Повторить' : 'Изменить'}</strong></div><button type="button" className="transactionEditorClose" onClick={onClose}>×</button></div>
        {loading && <div className="explorerTransactionsLoading">Загрузка перевода…</div>}
        {!loading && form && <div className="transactionEditorForm">
          <SmartSelect label="Со счёта" title="Счёт списания" value={form.from_account_id} options={accountOptions} onChange={setField('from_account_id')} placeholder="Выбрать счёт" />
          <SmartSelect label="На счёт" title="Счёт зачисления" value={form.to_account_id} options={accountOptions} onChange={setField('to_account_id')} placeholder="Выбрать счёт" />
          <label className="transactionEditorField"><span>Сумма списания{fromCurrency ? ` · ${fromCurrency}` : ''}</span><input type="number" inputMode="decimal" step="0.01" value={form.from_amount} onChange={updateInput('from_amount')} /></label>
          <div className="transferEditorDerived"><span>Зачисление</span><strong>{sameCurrency ? `${form.from_amount || '—'} ${toCurrency}` : `По курсу на дату · ${toCurrency || '—'}`}</strong></div>
          <label className="transactionEditorField"><span>Дата</span><input type="date" value={form.date} onChange={updateInput('date')} /></label>
          <label className="transactionEditorField"><span>Время</span><input type="time" value={form.time} onChange={updateInput('time')} /></label>
        </div>}
        <button type="submit" className="transactionEditorSave" disabled={saving || loading || !form}>{saving ? 'Сохранение…' : 'Сохранить'}</button>
      </form>
    </div>,
    document.body,
  )
}
