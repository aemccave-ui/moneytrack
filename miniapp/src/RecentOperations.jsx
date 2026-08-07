import { useRef, useState } from 'react'
import { deleteTransaction } from './api.js'

const ACTION_REVEAL = 176
const SWIPE_THRESHOLD = 46

const localDateValue = (date = new Date()) => {
  const offset = date.getTimezoneOffset() * 60000
  return new Date(date.getTime() - offset).toISOString().slice(0, 10)
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

function DetailRow({ label, value }) {
  return <div className="transactionDetailRow"><span>{label}</span><strong>{value ?? '—'}</strong></div>
}

function Editor({ operation, mode, onClose }) {
  const repeat = mode === 'repeat'
  const [form, setForm] = useState(() => ({
    transaction_type: operation.transaction_type || 'expense',
    amount: Math.abs(Number(operation.amount_original || 0)),
    currency: operation.currency_original || 'EUR',
    account: operation.account_name || '',
    category: operation.category_name || operation.category_id || '',
    date: repeat ? localDateValue() : String(operation.transaction_date || '').slice(0, 10),
    description: operation.description || '',
  }))

  const update = (field) => (event) => setForm((current) => ({ ...current, [field]: event.target.value }))

  return <div className="transactionEditorBackdrop visible" onClick={(event) => event.target === event.currentTarget && onClose()}>
    <section className="transactionEditorSheet" role="dialog" aria-modal="true" aria-label={repeat ? 'Повторить операцию' : 'Изменить операцию'}>
      <div className="transactionEditorHeader"><div><span>{repeat ? 'Новая операция' : 'Операция'}</span><strong>{repeat ? 'Повторить' : 'Изменить'}</strong></div><button type="button" className="transactionEditorClose" onClick={onClose} aria-label="Закрыть">×</button></div>
      <div className="transactionEditorForm">
        <label className="transactionEditorField"><span>Тип</span><select value={form.transaction_type} onChange={update('transaction_type')}><option value="expense">Расход</option><option value="income">Доход</option><option value="adjustment">Корректировка</option></select></label>
        <label className="transactionEditorField"><span>Сумма</span><input type="number" value={form.amount} onChange={update('amount')} /></label>
        <label className="transactionEditorField"><span>Валюта</span><input type="text" value={form.currency} onChange={update('currency')} /></label>
        <label className="transactionEditorField"><span>Счёт</span><input type="text" value={form.account} onChange={update('account')} /></label>
        <label className="transactionEditorField"><span>Категория</span><input type="text" value={form.category} onChange={update('category')} /></label>
        <label className="transactionEditorField"><span>Дата</span><input type="date" value={form.date} onChange={update('date')} /></label>
        <label className="transactionEditorField"><span>Описание</span><input type="text" value={form.description} onChange={update('description')} /></label>
      </div>
      <p className="transactionEditorNote">{repeat ? 'Интерфейс готов. Сохранение повторённой операции будет подключено следующим этапом.' : 'Интерфейс готов. Сохранение изменений будет подключено следующим этапом.'}</p>
      <button type="button" className="transactionEditorSave" disabled>Сохранить · скоро</button>
    </section>
  </div>
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
    setDragX(0)
    if (wasSwipe) {
      if (dx >= SWIPE_THRESHOLD) onActions(true)
      else onActions(false)
    }
  }

  const activate = () => {
    if (pointer.current.swiped) {
      pointer.current.swiped = false
      return
    }
    if (actionsOpen) onActions(false)
    else onExpand()
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
    onPointerCancel={() => { pointer.current.dragging = false; setDragX(0) }}
    onClick={activate}
    onKeyDown={(event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); activate() } }}
  >
    <div className="transactionSwipeActions" aria-hidden={!actionsOpen}>
      <button type="button" className="transactionSwipeAction repeat" onClick={(event) => { event.stopPropagation(); onRepeat() }}><span aria-hidden="true">↻</span><small>Повторить</small></button>
      <button type="button" className="transactionSwipeAction edit" onClick={(event) => { event.stopPropagation(); onEdit() }}><span aria-hidden="true">✎</span><small>Изменить</small></button>
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
    {editor && <Editor operation={editor.operation} mode={editor.mode} onClose={() => setEditor(null)} />}
    {busyId != null && <div className="transactionBusy" aria-live="polite">Удаление…</div>}
  </>
}
