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
  const parts = new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(date)
  return `${parts.find((part) => part.type === 'hour')?.value || '00'}:${parts.find((part) => part.type === 'minute')?.value || '00'}`
}

const sourceTimeValue = (value) => {
  if (!value) return localTimeValue()
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? localTimeValue() : localTimeValue(date)
}

const normalizeTimeInput = (value) => {
  const digits = String(value || '').replace(/\D/g, '').slice(0, 4)
  if (digits.length <= 2) return digits
  return `${digits.slice(0, 2)}:${digits.slice(2)}`
}

const validTime = (value) => {
  const match = /^(\d{2}):(\d{2})$/.exec(value)
  return Boolean(match && Number(match[1]) <= 23 && Number(match[2]) <= 59)
}

const formatDateInput = (value) => {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ''))
  return match ? `${match[3]}.${match[2]}.${match[1]}` : ''
}

const normalizeDateInput = (value) => {
  const digits = String(value || '').replace(/\D/g, '').slice(0, 8)
  if (digits.length <= 2) return digits
  if (digits.length <= 4) return `${digits.slice(0, 2)}.${digits.slice(2)}`
  return `${digits.slice(0, 2)}.${digits.slice(2, 4)}.${digits.slice(4)}`
}

const dateInputToIso = (value) => {
  const match = /^(\d{2})\.(\d{2})\.(\d{4})$/.exec(value)
  if (!match) return null
  const day = Number(match[1])
  const month = Number(match[2])
  const year = Number(match[3])
  const date = new Date(Date.UTC(year, month - 1, day))
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null
  return `${match[3]}-${match[2]}-${match[1]}`
}

const formatDateTime = (value) => {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return new Intl.DateTimeFormat('ru-RU', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(date)
}

const operationTypeLabel = (type) => ({ income: 'Доход', expense: 'Расход', openingbalance: 'Начальный остаток', adjustment: 'Корректировка' }[type] || type || 'Операция')

const idOf = (item) => item.id ?? item.account_id
const parentOf = (item) => item.parent_id ?? item.parent_account_id ?? item.parent_category_id ?? null

const flattenHierarchy = (items = []) => {
  const nodes = new Map(items.map((item) => [String(idOf(item)), { item, children: [] }]))
  const roots = []
  nodes.forEach((node) => {
    const parentId = parentOf(node.item)
    const parent = parentId == null ? null : nodes.get(String(parentId))
    if (parent && parent !== node) parent.children.push(node)
    else roots.push(node)
  })
  const compare = (a, b) => {
    const aOrder = Number(a.item.sort_order ?? 0)
    const bOrder = Number(b.item.sort_order ?? 0)
    if (aOrder !== bOrder) return aOrder - bOrder
    return String(a.item.name || a.item.account_name || a.item.code || '').localeCompare(String(b.item.name || b.item.account_name || b.item.code || ''), 'ru')
  }
  const result = []
  const visit = (node, depth) => {
    result.push({ ...node.item, depth, hasChildren: node.children.length > 0 })
    node.children.sort(compare).forEach((child) => visit(child, depth + 1))
  }
  roots.sort(compare).forEach((node) => visit(node, 0))
  return result
}

const normalizeAccounts = (items = []) => {
  const result = []
  const visit = (account, inheritedParentId = null) => {
    const normalized = inheritedParentId == null || parentOf(account) != null ? account : { ...account, parent_id: inheritedParentId }
    result.push(normalized)
    const id = idOf(account)
    ;(account.children || account.accounts || []).forEach((child) => visit(child, id))
  }
  items.forEach((account) => visit(account))
  return result
}

function CalendarIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 2v3M17 2v3M3.5 9h17M5.5 4h13a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>
}

function ClockIcon() {
  return <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" strokeWidth="1.8"/><path d="M12 7.5V12l3.2 2" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/></svg>
}

function DetailRow({ label, value }) {
  return <div className="transactionDetailRow"><span>{label}</span><strong>{value ?? '—'}</strong></div>
}

function ChoiceField({ fieldId, label, value, options, placeholder = 'Выбрать', onChange, disabled = false, openField, setOpenField }) {
  const open = openField === fieldId
  const selected = options.find((option) => String(option.value) === String(value))
  return <div className={`transactionEditorField transactionChoiceField ${open ? 'open' : ''}`} data-choice-field={fieldId}>
    <span>{label}</span>
    <button type="button" className="transactionChoiceButton" disabled={disabled} aria-haspopup="listbox" aria-expanded={open} onClick={() => setOpenField(open ? null : fieldId)}>
      <span className={selected ? '' : 'placeholder'}>{selected?.label || placeholder}</span><i aria-hidden="true">⌄</i>
    </button>
    {open && <div className="transactionChoiceMenu" role="listbox">
      {options.length ? options.map((option) => {
        const selectable = option.selectable !== false
        const selectedOption = String(option.value) === String(value)
        return <button type="button" role="option" aria-selected={selectedOption} aria-disabled={!selectable} disabled={!selectable} className={`${selectedOption ? 'selected' : ''} ${option.depth ? 'nested' : ''} ${!selectable ? 'branchOnly' : ''}`} style={{ '--choice-depth': option.depth || 0 }} key={String(option.value)} onClick={() => { if (!selectable) return; onChange(option.value); setOpenField(null) }}>
          <span className="transactionChoiceLabel">{option.depth > 0 && <i className="transactionChoiceBranch" aria-hidden="true">↳</i>}{option.label}</span>{option.meta && <small>{option.meta}</small>}{selectedOption && <b aria-hidden="true">✓</b>}
        </button>
      }) : <div className="transactionChoiceEmpty">Нет доступных значений</div>}
    </div>}
  </div>
}

function Editor({ operation, mode, onClose, referenceData, referenceLoading, referenceError }) {
  const repeat = mode === 'repeat'
  const initialTime = repeat ? localTimeValue() : sourceTimeValue(operation.transaction_date)
  const initialDate = repeat ? localDateValue() : String(operation.transaction_date || '').slice(0, 10)
  const [form, setForm] = useState(() => ({
    transaction_type: operation.transaction_type || 'expense',
    amount: Math.abs(Number(operation.amount_original || 0)),
    currency: operation.currency_original || 'EUR',
    account_id: operation.account_id ?? '',
    category_id: operation.category_id ?? '',
    date: initialDate,
    time: initialTime,
    description: operation.description || '',
  }))
  const [dateText, setDateText] = useState(() => formatDateInput(initialDate))
  const [openField, setOpenField] = useState(null)
  const editorRef = useRef(null)
  const datePickerRef = useRef(null)
  const update = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }))
  const setValue = (field) => (value) => setForm((current) => ({ ...current, [field]: value }))
  const typeOptions = [{ value: 'expense', label: 'Расход' }, { value: 'income', label: 'Доход' }, { value: 'adjustment', label: 'Корректировка' }]
  const currencyOptions = referenceData.currencies.map((item) => ({ value: item.code, label: item.code, meta: Number(item.usage_count || 0) > 0 ? 'использовалась' : '' }))
  const accountOptions = flattenHierarchy(referenceData.accounts).map((item) => ({ value: idOf(item), label: item.name || item.account_name || 'Счёт', meta: item.currency_code || '', depth: item.depth, selectable: !item.hasChildren }))
  const categoryOptions = flattenHierarchy(referenceData.categories).map((item) => ({ value: item.id, label: item.name || item.code, meta: item.code && item.name !== item.code ? item.code : '', depth: item.depth }))
  const timeInvalid = form.time.length === 5 && !validTime(form.time)
  const dateInvalid = dateText.length === 10 && !dateInputToIso(dateText)

  useEffect(() => {
    const closeMenus = (event) => {
      if (!event.target.closest('[data-choice-field]')) setOpenField(null)
    }
    document.addEventListener('pointerdown', closeMenus)
    return () => document.removeEventListener('pointerdown', closeMenus)
  }, [])

  const updateDateText = (value) => {
    const normalized = normalizeDateInput(value)
    setDateText(normalized)
    const iso = dateInputToIso(normalized)
    if (iso) setForm((current) => ({ ...current, date: iso }))
  }

  const openNativeDatePicker = () => {
    const picker = datePickerRef.current
    if (!picker) return
    if (typeof picker.showPicker === 'function') picker.showPicker()
    else picker.click()
  }

  return createPortal(<div className="transactionEditorBackdrop visible" onClick={(event) => event.target === event.currentTarget && onClose()}>
    <section ref={editorRef} className="transactionEditorSheet" role="dialog" aria-modal="true" aria-label={repeat ? 'Повторить операцию' : 'Изменить операцию'}>
      <div className="transactionEditorHeader"><div><span>{repeat ? 'Новая операция' : 'Операция'}</span><strong>{repeat ? 'Повторить' : 'Изменить'}</strong></div><button type="button" className="transactionEditorClose" onClick={onClose} aria-label="Закрыть">×</button></div>
      <div className="transactionEditorForm">
        <ChoiceField fieldId="type" label="Тип" value={form.transaction_type} options={typeOptions} onChange={setValue('transaction_type')} openField={openField} setOpenField={setOpenField} />
        <label className="transactionEditorField"><span>Сумма</span><input type="number" inputMode="decimal" value={form.amount} onChange={update('amount')} /></label>
        <ChoiceField fieldId="currency" label="Валюта" value={form.currency} options={currencyOptions} placeholder={referenceLoading ? 'Загрузка…' : 'Выбрать валюту'} onChange={setValue('currency')} disabled={referenceLoading} openField={openField} setOpenField={setOpenField} />
        <ChoiceField fieldId="account" label="Счёт" value={form.account_id} options={accountOptions} placeholder={referenceLoading ? 'Загрузка…' : operation.account_name || 'Выбрать счёт'} onChange={setValue('account_id')} disabled={referenceLoading} openField={openField} setOpenField={setOpenField} />
        <ChoiceField fieldId="category" label="Категория" value={form.category_id} options={categoryOptions} placeholder={referenceLoading ? 'Загрузка…' : operation.category_name || 'Выбрать категорию'} onChange={setValue('category_id')} disabled={referenceLoading} openField={openField} setOpenField={setOpenField} />
        <label className={`transactionEditorField transactionDateField ${dateInvalid ? 'invalid' : ''}`}><span>Дата</span><div className="transactionNativePicker transactionDateText"><input type="text" inputMode="numeric" autoComplete="off" maxLength="10" placeholder="ДД.ММ.ГГГГ" value={dateText} onFocus={() => setOpenField(null)} onChange={(event) => updateDateText(event.target.value)} onBlur={() => { if (!dateInputToIso(dateText)) setDateText(formatDateInput(form.date)) }} /><button type="button" className="transactionPickerButton" aria-label="Выбрать дату" onClick={openNativeDatePicker}><CalendarIcon /></button><input ref={datePickerRef} className="transactionHiddenDatePicker" type="date" value={form.date} onChange={(event) => { setForm((current) => ({ ...current, date: event.target.value })); setDateText(formatDateInput(event.target.value)) }} tabIndex="-1" aria-hidden="true" /></div></label>
        <label className={`transactionEditorField transactionTimeField ${timeInvalid ? 'invalid' : ''}`}><span>Время</span><div className="transactionNativePicker transactionTime24"><input type="text" inputMode="numeric" autoComplete="off" maxLength="5" placeholder="HH:MM" value={form.time} onFocus={() => setOpenField(null)} onChange={(event) => setForm((current) => ({ ...current, time: normalizeTimeInput(event.target.value) }))} onBlur={() => { if (!validTime(form.time)) setForm((current) => ({ ...current, time: initialTime })) }} /><i className="transactionPickerIcon"><ClockIcon /></i></div></label>
        <label className="transactionEditorField transactionDescriptionField"><span>Описание</span><input type="text" value={form.description} onFocus={() => setOpenField(null)} onChange={update('description')} /></label>
      </div>
      {referenceError && <p className="transactionEditorReferenceError">Справочники сейчас недоступны. Исходные значения сохранены.</p>}
      <p className="transactionEditorNote">{repeat ? 'Интерфейс готов. Сохранение повторённой операции будет подключено следующим этапом.' : 'Интерфейс готов. Сохранение изменений будет подключено следующим этапом.'}</p>
      <button type="button" className="transactionEditorSave" disabled>Сохранить · скоро</button>
    </section>
  </div>, document.body)
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
    if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 8) { state.dragging = false; state.swiped = false; setDragX(0); return }
    if (dx > 8) { state.swiped = true; setDragX(Math.min(ACTION_REVEAL, dx)) }
  }
  const pointerUp = (event) => {
    const state = pointer.current
    const dx = event.clientX - state.startX
    const wasSwipe = state.swiped
    state.dragging = false
    state.swiped = false
    setDragX(0)
    if (wasSwipe) onActions(dx >= SWIPE_THRESHOLD)
  }
  const actionPointerUp = (handler) => (event) => { event.preventDefault(); event.stopPropagation(); handler() }
  const activate = () => { if (actionsOpen) onActions(false); else onExpand() }

  return <article className={`transaction ${expanded ? 'detailsOpen' : ''} ${actionsOpen ? 'actionsOpen' : ''}`} style={{ '--transaction-swipe-x': `${dragX}px` }} role="button" tabIndex={0} aria-expanded={expanded} aria-label={`${tx.description || tx.account_name || 'Операция'}. Нажмите для деталей, проведите вправо для действий.`} onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={pointerUp} onPointerCancel={() => { pointer.current.dragging = false; pointer.current.swiped = false; setDragX(0) }} onClick={activate} onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); activate() } }}>
    <div className="transactionSwipeActions" aria-hidden={!actionsOpen}>
      <button type="button" className="transactionSwipeAction repeat" onPointerUp={actionPointerUp(onRepeat)} onClick={(event) => { event.preventDefault(); event.stopPropagation() }}><span aria-hidden="true">↻</span><small>Повторить</small></button>
      <button type="button" className="transactionSwipeAction edit" onPointerUp={actionPointerUp(onEdit)} onClick={(event) => { event.preventDefault(); event.stopPropagation() }}><span aria-hidden="true">✎</span><small>Изменить</small></button>
      <button type="button" className="transactionSwipeAction delete" onClick={(event) => { event.stopPropagation(); onDelete() }}><span aria-hidden="true">×</span><small>Удалить</small></button>
    </div>
    <div className={`transactionIcon ${income ? 'income' : 'expense'}`}>{income ? '↑' : '↓'}</div>
    <div className="transactionBody"><strong>{tx.description || tx.account_name || 'Операция'}</strong><span>{tx.account_name || 'Счёт'}</span></div>
    <div className={`transactionAmount sensitive ${income ? 'incomeText' : ''}`}>{privacy ? '••••' : `${income ? '+' : '−'}${money(Math.abs(tx.amount_original), tx.currency_original || baseCurrency)}`}</div>
    {expanded && <div className="transactionDetails" onClick={(event) => event.stopPropagation()}><DetailRow label="Тип" value={operationTypeLabel(tx.transaction_type)} /><DetailRow label="Сумма" value={String(tx.amount_original ?? '—')} /><DetailRow label="Валюта" value={tx.currency_original || '—'} /><DetailRow label="Счёт" value={tx.account_name || '—'} /><DetailRow label="Категория" value={tx.category_name || tx.category_id || '—'} /><DetailRow label="Дата" value={formatDateTime(tx.transaction_date)} /><DetailRow label="Описание" value={tx.description || '—'} /></div>}
  </article>
}

export function RecentOperations({ groups, transactions, privacy, baseCurrency, money, dayLabel, onDeleted }) {
  const [expandedId, setExpandedId] = useState(null)
  const [actionsId, setActionsId] = useState(null)
  const [editor, setEditor] = useState(null)
  const [busyId, setBusyId] = useState(null)
  const [referenceData, setReferenceData] = useState({ currencies: [], categories: [], accounts: [] })
  const [referenceLoaded, setReferenceLoaded] = useState(false)
  const [referenceError, setReferenceError] = useState('')
  const referenceLoading = Boolean(editor && !referenceLoaded && !referenceError)

  useEffect(() => {
    if (!editor || referenceLoaded) return undefined
    const controller = new AbortController()
    Promise.all([getTransactionReference(controller.signal), getAccounts(controller.signal)])
      .then(([reference, accountData]) => {
        setReferenceData({ currencies: reference?.currencies || [], categories: reference?.categories || [], accounts: normalizeAccounts(accountData?.accounts || accountData?.items || []) })
        setReferenceLoaded(true)
      })
      .catch((error) => { if (error?.name !== 'AbortError') setReferenceError(error?.message || 'Не удалось загрузить справочники') })
    return () => controller.abort()
  }, [editor, referenceLoaded])

  const openEditor = (tx, mode) => {
    setActionsId(null)
    if (!referenceLoaded) setReferenceError('')
    setEditor({ operation: tx, mode })
  }

  const confirmDelete = (tx) => {
    const description = tx.description || tx.account_name || 'Операция'
    const amount = `${Math.abs(Number(tx.amount_original || 0))} ${tx.currency_original || ''}`.trim()
    const message = `Удалить операцию «${description}»${amount ? ` на ${amount}` : ''}?`
    if (window.Telegram?.WebApp?.showConfirm) return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
    return Promise.resolve(window.confirm(message))
  }
  const showError = (message) => { if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message); else window.alert(message) }
  const remove = async (tx) => {
    if (busyId != null || !(await confirmDelete(tx))) return
    setBusyId(tx.id)
    try { await deleteTransaction(tx.id); setExpandedId(null); setActionsId(null); await onDeleted?.() }
    catch (error) { showError(error.message || 'Не удалось удалить операцию') }
    finally { setBusyId(null) }
  }

  return <>
    <section className="section transactionsSection"><div className="sectionHeader"><h2>Последние операции</h2></div><div className="transactionPanel">
      {groups.map(([date, items]) => <div className="transactionGroup" key={date}><div className="dateLabel">{dayLabel(date)}</div>{items.map((tx) => <TransactionRow key={tx.id} tx={tx} privacy={privacy} baseCurrency={baseCurrency} money={money} expanded={String(expandedId) === String(tx.id)} actionsOpen={String(actionsId) === String(tx.id)} onExpand={() => { setActionsId(null); setExpandedId((current) => String(current) === String(tx.id) ? null : tx.id) }} onActions={(open) => { setExpandedId(null); setActionsId(open ? tx.id : null) }} onRepeat={() => openEditor(tx, 'repeat')} onEdit={() => openEditor(tx, 'edit')} onDelete={() => remove(tx)} />)}</div>)}
      {!transactions.length && <div className="emptyCard">Здесь появятся последние операции</div>}
    </div></section>
    {editor && <Editor operation={editor.operation} mode={editor.mode} onClose={() => setEditor(null)} referenceData={referenceData} referenceLoading={referenceLoading} referenceError={referenceError} />}
    {busyId != null && <div className="transactionBusy" aria-live="polite">Удаление…</div>}
  </>
}
