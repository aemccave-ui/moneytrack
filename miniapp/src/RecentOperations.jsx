import { useEffect, useMemo, useState } from 'react'
import { deleteTransaction, deleteTransfer, getTransactionReference } from './api.js'
import { SwipeReveal } from './SwipeReveal.jsx'
import TransactionEditor from './TransactionEditor.jsx'
import TransferEditor from './TransferEditor.jsx'

let categoryNamePromise = null

function loadCategoryNames() {
  if (!categoryNamePromise) {
    categoryNamePromise = getTransactionReference()
      .then((refs) => new Map((refs?.categories || []).map((item) => [String(item.id), item.name || item.code || String(item.id)])))
      .catch((error) => {
        categoryNamePromise = null
        throw error
      })
  }
  return categoryNamePromise
}

function transferIdOf(tx) {
  if (tx?.transfer_id != null) return Number(tx.transfer_id)
  const match = String(tx?.id || '').match(/^transfer-(\d+)$/)
  return match ? Number(match[1]) : null
}

const operationTypeLabel = (type) => ({
  income: 'Доход',
  expense: 'Расход',
  openingbalance: 'Начальный остаток',
  adjustment: 'Корректировка',
  transfer: 'Перевод',
}[type] || type || 'Операция')

function SwipeActionIcon({ name }) {
  if (name === 'repeat') return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 7v5h-5M4 17v-5h5M6.1 9a7 7 0 0 1 11.7-2L20 9M4 15l2.2 2a7 7 0 0 0 11.7-2" /></svg>
  if (name === 'edit') return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20h4l11-11-4-4L4 16v4ZM13.5 6.5l4 4" /></svg>
  return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7h14M9 7V4h6v3M8 10v7M12 10v7M16 10v7M6 7l1 13h10l1-13" /></svg>
}

function confirmAction(message) {
  if (window.Telegram?.WebApp?.showConfirm) {
    return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  }
  return Promise.resolve(window.confirm(message))
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function DetailRow({ label, value }) {
  return <div className="transactionDetailRow"><span>{label}</span><strong>{value ?? '—'}</strong></div>
}

function TransactionRow({ tx, privacy, baseCurrency, money, expanded, onExpand, onEdit, onRepeat, onDelete, categoryName }) {
  const transfer = tx.transaction_type === 'transfer'
  const incoming = transfer && tx.transfer_direction === 'incoming'
  const positive = tx.transaction_type === 'income' || incoming
  const amountCurrency = tx.currency_original || tx.currency || baseCurrency
  const rawAmount = Number(tx.amount_original ?? tx.amount ?? 0)
  const amount = positive ? Math.abs(rawAmount) : -Math.abs(rawAmount)
  const transferReason = 'Перевод связан с двумя счетами и редактируется как единая парная операция.'

  const actions = [
    { key: 'repeat', label: 'Повторить', icon: <SwipeActionIcon name="repeat" />, onClick: onRepeat },
    { key: 'edit', label: 'Изменить', icon: <SwipeActionIcon name="edit" />, onClick: onEdit },
    { key: 'delete', label: 'Удалить', icon: <SwipeActionIcon name="delete" />, danger: true, onClick: onDelete },
  ]

  return (
    <article className={`transactionCard ${expanded ? 'expanded' : ''}`}>
      <SwipeReveal id={`tx:${tx.id}`} actions={actions} actionWidth={56} className="transactionSwipeReveal">
        {({ open }) => (
          <button
            type="button"
            className="transactionRow"
            onClick={() => { if (!open) onExpand() }}
            aria-expanded={expanded}
            aria-label={`${tx.description || operationTypeLabel(tx.transaction_type)}. Смахните влево для действий.`}
          >
            <span className={`transactionTypeMark ${positive ? 'income' : 'expense'}`} aria-hidden="true">{positive ? '↑' : '↓'}</span>
            <span className="transactionIdentity"><strong>{tx.description || operationTypeLabel(tx.transaction_type)}</strong><small>{tx.account_name || categoryName || tx.category_name || operationTypeLabel(tx.transaction_type)}</small></span>
            <strong className={`transactionAmount ${positive ? 'income' : 'expense'} sensitive`}>{privacy ? '••••' : money(amount, amountCurrency)}</strong>
          </button>
        )}
      </SwipeReveal>
      {expanded && (
        <div className="transactionDetails">
          <DetailRow label="Тип" value={transfer ? (incoming ? 'Входящий перевод' : 'Исходящий перевод') : operationTypeLabel(tx.transaction_type)} />
          <DetailRow label="Счёт" value={tx.account_name || tx.account_id} />
          {!transfer && <DetailRow label="Категория" value={categoryName || tx.category_name || tx.category_code || tx.category_id} />}
          <DetailRow label="Валюта" value={amountCurrency} />
          <DetailRow label="Дата" value={String(tx.transaction_date || '').replace('T', ' ').slice(0, 16)} />
          <DetailRow label="Описание" value={tx.description} />
          {transfer && <div className="transactionTransferReason">{transferReason}</div>}
        </div>
      )}
    </article>
  )
}

export function RecentOperations({
  groups,
  transactions,
  privacy,
  baseCurrency,
  money,
  dayLabel,
  onDeleted,
  title = 'Последние операции',
  emptyLabel = 'Операций пока нет',
}) {
  const [expandedId, setExpandedId] = useState(null)
  const [editor, setEditor] = useState(null)
  const [busyId, setBusyId] = useState(null)
  const [categoryNames, setCategoryNames] = useState(() => new Map())

  useEffect(() => {
    let alive = true
    loadCategoryNames().then((names) => alive && setCategoryNames(names)).catch(() => {})
    return () => { alive = false }
  }, [])

  const groupList = useMemo(() => groups || (() => {
    const byDate = new Map()
    ;(transactions || []).forEach((tx) => {
      const key = String(tx.transaction_date || '').slice(0, 10)
      if (!byDate.has(key)) byDate.set(key, [])
      byDate.get(key).push(tx)
    })
    return [...byDate.entries()]
  })(), [groups, transactions])

  const remove = async (tx) => {
    if (busyId != null) return
    const transfer = tx.transaction_type === 'transfer'
    const transferId = transfer ? transferIdOf(tx) : null
    if (transfer && !transferId) {
      showError('Не удалось определить перевод.')
      return
    }
    if (!(await confirmAction(transfer ? 'Удалить этот перевод целиком?' : 'Удалить эту операцию?'))) return
    setBusyId(tx.id)
    try {
      if (transfer) await deleteTransfer(transferId)
      else await deleteTransaction(tx.id)
      setExpandedId(null)
      await onDeleted?.(tx)
    } catch (error) {
      showError(error?.message || (transfer ? 'Не удалось удалить перевод' : 'Не удалось удалить операцию'))
    } finally {
      setBusyId(null)
    }
  }

  const saved = async () => {
    setExpandedId(null)
    await onDeleted?.()
  }

  const openEditor = (tx, mode) => setEditor({
    operation: tx,
    mode,
    kind: tx.transaction_type === 'transfer' ? 'transfer' : 'transaction',
  })

  return (
    <>
      <section className="section recentOperationsSection">
        <div className="sectionHeader"><h2>{title}</h2></div>
        {!groupList.length && <div className="emptyCard">{emptyLabel}</div>}
        <div className="transactionGroups">
          {groupList.map(([date, items]) => (
            <section className="transactionGroup" key={date}>
              <h3>{dayLabel ? dayLabel(date) : date}</h3>
              <div className="transactionList">
                {items.map((tx) => {
                  const id = String(tx.id)
                  return (
                    <TransactionRow
                      key={id}
                      tx={tx}
                      privacy={privacy}
                      baseCurrency={baseCurrency}
                      money={money}
                      expanded={expandedId === id}
                      onExpand={() => setExpandedId((current) => current === id ? null : id)}
                      onRepeat={() => openEditor(tx, 'repeat')}
                      onEdit={() => openEditor(tx, 'edit')}
                      onDelete={() => remove(tx)}
                      categoryName={tx.category_id == null ? '' : categoryNames.get(String(tx.category_id))}
                    />
                  )
                })}
              </div>
            </section>
          ))}
        </div>
      </section>
      {editor?.kind === 'transaction' && <TransactionEditor operation={editor.operation} mode={editor.mode} onClose={() => setEditor(null)} onSaved={saved} />}
      {editor?.kind === 'transfer' && <TransferEditor operation={editor.operation} mode={editor.mode} onClose={() => setEditor(null)} onSaved={saved} />}
      {busyId != null && <div className="transactionBusy" role="status">Удаление…</div>}
    </>
  )
}
