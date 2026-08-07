import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { deleteTransaction, getAccounts, getTransactionReference } from './api.js'

const ACTION_REVEAL = 176
const SWIPE_THRESHOLD = 46

const localDateValue = (date = new Date()) => {
  const offset = date.getTimezoneOffset() * 60000
  return new Date(date.getTime() - offset).toISOString().slice(0, 10)
}

const localTimeValue = (date = new Date()) => {
  const parts = new Intl.DateTimeFormat('en-GB', {
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(date)
  const hour = parts.find((part) => part.type === 'hour')?.value || '00'
  const minute = parts.find((part) => part.type === 'minute')?.value || '00'
  return `${hour}:${minute}`
}

const sourceTimeValue = (value) => {
  if (!value) return localTimeValue()
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? localTimeValue() : localTimeValue(date)
}

const formatDateTime = (value) => {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).format(date)
}

const operationTypeLabel = (type) => {
  if (type === 'income') return 'Доход'
  if (type === 'expense') return 'Расход'
  if (type === 'openingbalance') return 'Начальный остаток'
  if (type === 'adjustment') return 'Корректировка'
  return type || 'Операция'
}

const flattenAccounts = (items = []) => {
  const result = []
  const visit = (account) => {
    result.push(account)
    ;(account.children || account.accounts || []).forEach(visit)
  }
  items.forEach(visit)
  return result
}

function DetailRow({ label, value }) {
  return <div className="transactionDetailRow"><span>{label}</span><strong>{value ?? '—'}</strong></div>
}

function ChoiceField({ label, value, options, placeholder = 'Выбрать', onChange, disabled = false }) {
  const [open, setOpen] = useState(false)
  const selected = options.find((option) => String(option.value) === String(value))

  return <label className={`transactionEditorField transactionChoiceField ${open ? 'open' : ''}`}>
    <span>{label}</span>
    <button
      type="button"
      className="transactionChoiceButton"
      disabled={disabled}
      aria-haspopup="listbox"
      aria-expanded={open}
      onClick={() => setOpen((current) => !current)}
    >
      <span className={selected ? '' : 'placeholder'}>{selected?.label || placeholder}</span>
      <i aria-hidden="true">⌄</i>
    </button>
    {open && <div className="transactionChoiceMenu" role="listbox">
      {options.length ? options.map((option) => <button
        type="button"
        role="option"
        aria-selected={String(option.value) === String(value)}
        className={String(option.value) === String(value) ? 'selected' : ''}
        key={String(option.value)}
        onClick={() => { onChange(option.value); setOpen(false) }}
      >
        <span>{option.label}</span>
        {option.meta && <small>{option.meta}</small>}
        {String(option.value) === String(value) && <b aria-hidden="true">✓</b>}
      </button>) : <div className="transactionChoiceEmpty">Нет доступных значений</div>}
    </div>}
  </label>
}

function Editor({ operation, mode, onClose, referenceData, referenceLoading, referenceError }) {
  const repeat = mode === 'repeat'
  const [form, setForm] = useState(() => ({
    transaction_type: operation.transaction_type || 'expense',
    amount: Math.abs(Number(operation.amount_original || 0)),
    currency: operation.currency_original || 'EUR',
    account_id: operation.account_id ?? '',
    category_id: operation.category_id ?? '',
    date: repeat ? localDateValue() : String(operation.transaction_date || '').slice(0, 10),
    time: repeat ? localTimeValue() : sourceTimeValue(operation.transaction_date),
    description: operation.description || '',
  }))

  const update = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }))
  const setValue = (field) => (value) => setForm((current) => ({ ...current, [field]: value }))

  const typeOptions = [
    { value: 'expense', label: 'Расход' },
    { value: 'income', label: 'Доход' },
    { value: 'adjustment', label: 'Корректировка' },
  ]
  const currencyOptions = referenceData.currencies.map((currency) => ({
    value: currency.code, label: currency.code,
  }))
  const accountOptions = referenceData.accounts.map((account) => ({
    value: account.id ?? account.account_id,
    label: account.name || account.account_name || 'Счёт',
    meta: account.currency_code || '',
  }))
  const categoryOptions = referenceData.categories.map((category) => ({
    value: category.id,
    label: category.name || category.code,
    meta: category.code && category.name !== category.code ? category.code : '',
  }))

  const modal = <div className="transactionEditorBackdrop visible" onClick={(event) => event.target === event.currentTarget && onClose()}>
    <section className="transactionEditorSheet" role="dialog" aria-modal="true" aria-label={repeat ? 'Повторить операцию' : 'Изменить операцию'}>
      <div className="transactionEditorHeader"><div><span>{repeat ? 'Новая операция' : 'Операция'}</span><strong>{repeat ? 'Повторить' : 'Изменить'}</strong></div><button type="button" className="transactionEditorClose" onClick={onClose} aria-label="Закрыть">×</button></div>
      <div className="transactionEditorForm">
        <ChoiceField label="Тип" value={form.transaction_type} options={typeOptions} onChange={setValue('transaction_type')} />
        <label className="transactionEditorField"><span>Сумма</span><input type="number" inputMode="decimal" value={form.amount} onChange={update('amount')} /></label>
        <ChoiceField label="Валюта" value={form.currency} options={currencyOptions} placeholder={referenceLoading ? 'Загрузка…' : 'Выбрать валюту'} onChange={setValue('currency')} disabled={referenceLoading} />
        <ChoiceField label="Счёт" value={form.account_id} options={accountOptions} placeholder={referenceLoading ? 'Загрузка…' : operation.account_name || 'Выбрать счёт'} onChange={setValue('account_id')} disabled={referenceLoading} />
        <ChoiceField label="Категория" value={form.category_id} options={categoryOptions} placeholder={referenceLoading ? 'Загрузка…' : operation.category_name || 'Выбрать категорию'} onChange={setValue('category_id')} disabled={referenceLoading} />
        <label className="transactionEditorField transactionDateField"><span>Дата</span><div className="transactionNativePicker"><input type="date" value={form.date} onChange={update('date')} /><i aria-hidden="true">▦</i></div></label>
        <label className="transactionEditorField transactionTimeField"><span>Время</span><div className="transactionNativePicker"><input type="time" value={form.time} onChange={update('time')} step="60" /><i aria-hidden="true">◷</i></div></label>
        <label className="transactionEditorField transactionDescriptionField"><span>Описание</span><input type="text" value={form.description} onChange={update('description')} /></label>
      </div>
      {referenceError && <p className="transactionEditorReferenceError">Справочники сейчас недоступны. Исходные значения сохранены.</p>}
      <p className="transactionEditorNote">{repeat ? 'Интерфейс готов. Сохранение повторённой операции будет подключено следующим этапом.' : 'Интерфейс готов. Сохранение изменений будет подключено следующим этапом.'}</p>
      <button type="button" className="transactionEditorSave" disabled>Сохранить · скоро</button>
    </section>
  </div>

  return createPortal(modal, document.body)
}

function TransactionRow({ tx, privacy, baseCurrency, money, expanded, actionsOpen, onExpand, onActions, onEdit, onRepeat, onDelete }) {
  const income = tx.transaction_type === 'income'
  const pointer = useRef({ startX: 0, startY: 0, dragging: false, swiped: false })
  const [dragX, setDragX] = useState(0)

  const pointerDown = (event) => {
    if (event.target.closest('button, .transactionDetails')) return
    pointer.current = { startX: event.clientX, startY: event.clientY, dragging: true, swiped: false }
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  const pointerMove = (event) => {
    const state = pointer.current
    if (!state.dragging) return
    const dx = event.clientX - state.startX
    const dy = event.clientY - state.startY
    if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 8) {
      state.dragging = false
      state.swiped = false
      setDragX(0)
      return
    }
    if (dx > 8) {
      state.swiped = true
      setDragX(Math.min(ACTION_REVEAL, dx))
    }
  }

  const pointerUp = (event) => {
    const state = pointer.current
    const dx = event.clientX - state.startX
    const wasSwipe = state.swiped
    state.dragging = false
    state.swiped = false
    setDragX(0)
    if (wasSwipe) {
      if (dx >= SWIPE_THRESHOLD) onActions(true)
      else onActions(false)
    }
  }

  const activate = () => {
    if (actionsOpen) onActions(false)
    else onExpand()
  }

  const actionPointerUp = (handler) => (event) => {
    event.preventDefault()
    event.stopPropagation()
    handler()
  }

  return <article
    className={`transaction ${expanded ? 'detailsOpen' : ''} ${actionsOpen ? 'actionsOpen' : ''}`}
    style={{ '--transaction-swipe-x': `${dragX}px` }}
    role="button"
    tabIndex={0}
    aria-expanded={expanded}
    aria-label={`${tx.description || tx.account_name || 'Операция'}. Нажмите для деталей, проведите вправо для действий.`}
    onPointerDown={pointerDown}
    onPointerMove={pointerMove}
    onPointerUp={pointerUp}
    onPointerCancel={() => { pointer.current.dragging = false; pointer.current.swiped = false; setDragX(0) }}
    onClick={activate}
    onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); activate() } }}
  >
    <div className="transactionSwipeActions" aria-hidden={!actionsOpen}>
      <button type="button" className="transactionSwipeAction repeat" onPointerUp={actionPointerUp(onRepeat)} onClick={(event) => { event.preventDefault(); event.stopPropagation() }}><span aria-hidden="true">↻</span><small>Повторить</small></button>
      <button type="button" className="transactionSwipeAction edit" onPointerUp={actionPointerUp(onEdit)} onClick={(event) => { event.preventDefault(); event.stopPropagation() }}><span aria-hidden="true">✎</span><small>Изменить</small></button>
      <button type="button" className="transactionSwipeAction delete" onClick={(event) => { event.stopPropagation(); onDelete() }}><span aria-hidden="true">×</span><small>Удалить</small></button>
    </div>
    <div className={`transactionIcon ${income ? 'income' : 'expense'}`}>{income ? '↑' : '↓'}</div>
    <div className="transactionBody"><strong>{tx.description || tx.account_name || 'Операция'}</strong><span>{tx.account_name || 'Счёт'}</span></div>
    <div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>{privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || baseCurrency)}`}</div>
    {expanded && <div className="transactionDetails" onClick={(event) => event.stopPropagation()}>
      <DetailRow label="Тип" value={operationTypeLabel(tx.transaction_type)} />
      <DetailRow label="Сумма" value={String(tx.amount_original ?? '—')} />
      <DetailRow label="Валюта" value={tx.currency_original || '—'} />
      <DetailRow label="Счёт" value={tx.account_name || '—'} />
      <DetailRow label="Категория" value={tx.category_name || tx.category_id || '—'} />
      <DetailRow label="Дата" value={formatDateTime(tx.transaction_date)} />
      <DetailRow label="Описание" value={tx.description || '—'} />
    </div>}
  </article>
}

export function RecentOperations({ groups, transactions, privacy, baseCurrency, money, dayLabel, onDeleted }) {
  const [expandedId, setExpandedId] = useState(null)
  const [actionsId, setActionsId] = useState(null)
  const [editor, setEditor] = useState(null)
  const [busyId, setBusyId] = useState(null)
  const [referenceData, setReferenceData] = useState({ currencies: [], categories: [], accounts: [] })
  const [referenceLoaded, setReferenceLoaded] = useState(false)
  const [referenceLoading, setReferenceLoading] = useState(false)
  const [referenceError, setReferenceError] = useState('')

  useEffect(() => {
    if (!editor || referenceLoaded || referenceLoading) return undefined
    const controller = new AbortController()
    setReferenceLoading(true)
    setReferenceError('')
    Promise.all([
      getTransactionReference(controller.signal),
      getAccounts(controller.signal),
    ]).then(([reference, accountData]) => {
      setReferenceData({
        currencies: reference?.currencies || [],
        categories: reference?.categories || [],
        accounts: flattenAccounts(accountData?.accounts || accountData?.items || []),
      })
      setReferenceLoaded(true)
    }).catch((error) => {
      if (error?.name !== 'AbortError') setReferenceError(error?.message || 'Не удалось загрузить справочники')
    }).finally(() => setReferenceLoading(false))
    return () => controller.abort()
  }, [editor, referenceLoaded, referenceLoading])

  const confirmDelete = (tx) => {
    const description = tx.description || tx.account_name || 'Операция'
    const amount = `${Math.abs(Number(tx.amount_original || 0))} ${tx.currency_original || ''}`.trim()
    const message = `Удалить операцию «${description}»${amount ? ` на ${amount}` : ''}?`
    if (window.Telegram?.WebApp?.showConfirm) return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
    return Promise.resolve(window.confirm(message))
  }

  const showError = (message) => {
    if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
    else window.alert(message)
  }

  const remove = async (tx) => {
    if (busyId != null || !(await confirmDelete(tx))) return
    setBusyId(tx.id)
    try {
      await deleteTransaction(tx.id)
      setExpandedId(null)
      setActionsId(null)
      await onDeleted?.()
    } catch (error) {
      showError(error.message || 'Не удалось удалить операцию')
    } finally {
      setBusyId(null)
    }
  }

  return <>
    <section className="section transactionsSection">
      <div className="sectionHeader"><h2>Последние операции</h2></div>
      <div className="transactionPanel">
        {groups.map(([date, items]) => <div className="transactionGroup" key={date}>
          <div className="dateLabel">{dayLabel(date)}</div>
          {items.map((tx) => <TransactionRow
            key={tx.id}
            tx={tx}
            privacy={privacy}
            baseCurrency={baseCurrency}
            money={money}
            expanded={String(expandedId) === String(tx.id)}
            actionsOpen={String(actionsId) === String(tx.id)}
            onExpand={() => { setActionsId(null); setExpandedId((current) => String(current) === String(tx.id) ? null : tx.id) }}
            onActions={(open) => { setExpandedId(null); setActionsId(open ? tx.id : null) }}
            onRepeat={() => { setActionsId(null); setEditor({ operation: tx, mode: 'repeat' }) }}
            onEdit={() => { setActionsId(null); setEditor({ operation: tx, mode: 'edit' }) }}
            onDelete={() => remove(tx)}
          />)}
        </div>)}
        {!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}
      </div>
    </section>
    {editor && <Editor
      operation={editor.operation}
      mode={editor.mode}
      onClose={() => setEditor(null)}
      referenceData={referenceData}
      referenceLoading={referenceLoading}
      referenceError={referenceError}
    />}
    {busyId != null && <div className="transactionBusy" aria-live="polite">Удаление…</div>}
  </>
}
