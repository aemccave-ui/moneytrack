import { useEffect, useRef, useState } from 'react'
import { deleteTransaction } from './api.js'

const ACTION_REVEAL = 176
const SWIPE_THRESHOLD = 46

const operationTypeLabel = (type) => ({
  income: 'Доход',
  expense: 'Расход',
  openingbalance: 'Начальный остаток',
  adjustment: 'Корректировка',
  transfer: 'Перевод',
}[type] || type || 'Операция')

function confirmAction(message) {
  if (window.Telegram?.WebApp?.showConfirm) {
    return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  }
  return Promise.resolve(window.confirm(message))
}

function showInfo(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function DetailRow({ label, value }) {
  return <div className="transactionDetailRow"><span>{label}</span><strong>{value ?? '—'}</strong></div>
}

function TransactionRow({
  tx,
  privacy,
  baseCurrency,
  money,
  expanded,
  actionsOpen,
  onExpand,
  onActionsOpen,
  onActionsClose,
  onDeleted,
}) {
  const pointer = useRef({ startX: 0, startY: 0 })
  const [dragX, setDragX] = useState(0)
  const transfer = tx.transaction_type === 'transfer'
  const incoming = transfer && tx.transfer_direction === 'incoming'
  const positive = tx.transaction_type === 'income' || incoming
  const amountCurrency = tx.currency_original || tx.currency || baseCurrency
  const rawAmount = Number(tx.amount_original ?? tx.amount ?? 0)
  const amount = positive ? Math.abs(rawAmount) : -Math.abs(rawAmount)

  useEffect(() => {
    if (!actionsOpen) return undefined
    const timer = window.setTimeout(onActionsClose, 2000)
    return () => window.clearTimeout(timer)
  }, [actionsOpen, onActionsClose])

  const pointerDown = (event) => {
    pointer.current.startX = event.clientX
    pointer.current.startY = event.clientY
  }

  const pointerMove = (event) => {
    const dx = event.clientX - pointer.current.startX
    const dy = event.clientY - pointer.current.startY
    if (Math.abs(dx) > Math.abs(dy) && dx < 0) setDragX(Math.max(-ACTION_REVEAL, dx))
  }

  const pointerUp = () => {
    if (dragX < -SWIPE_THRESHOLD) {
      setDragX(0)
      onActionsOpen()
    } else {
      setDragX(0)
      if (actionsOpen) onActionsClose()
    }
  }

  const remove = async () => {
    if (transfer) {
      showInfo('Перевод не удаляется через endpoint обычной операции.')
      return
    }
    if (!(await confirmAction('Удалить эту операцию?'))) return
    try {
      await deleteTransaction(tx.id)
      onActionsClose()
      await onDeleted?.(tx)
    } catch (error) {
      showInfo(error?.message || 'Не удалось удалить операцию')
    }
  }

  return (
    <article className={`transactionCard ${expanded ? 'expanded' : ''}`}>
      <div className="transactionSwipeShell">
        <div className="transactionSwipeActions" aria-hidden={!actionsOpen}>
          <button type="button" disabled={transfer} onClick={() => showInfo('Повтор операции будет подключён отдельным write-contract.')}>Повторить</button>
          <button type="button" disabled={transfer} onClick={() => showInfo('Редактирование операции будет подключено отдельным write-contract.')}>Изменить</button>
          <button type="button" className="danger" disabled={transfer} onClick={remove}>Удалить</button>
        </div>
        <button
          type="button"
          className="transactionRow"
          style={{ transform: `translateX(${actionsOpen ? -ACTION_REVEAL : dragX}px)` }}
          onPointerDown={pointerDown}
          onPointerMove={pointerMove}
          onPointerUp={pointerUp}
          onPointerCancel={() => setDragX(0)}
          onClick={() => { if (Math.abs(dragX) < 8 && !actionsOpen) onExpand() }}
          aria-expanded={expanded}
        >
          <span className={`transactionTypeMark ${positive ? 'income' : 'expense'}`} aria-hidden="true">{positive ? '↑' : '↓'}</span>
          <span className="transactionIdentity"><strong>{tx.description || operationTypeLabel(tx.transaction_type)}</strong><small>{tx.account_name || tx.category_name || operationTypeLabel(tx.transaction_type)}</small></span>
          <strong className={`transactionAmount ${positive ? 'income' : 'expense'} sensitive`}>{privacy ? '••••' : money(amount, amountCurrency)}</strong>
        </button>
      </div>
      {expanded && (
        <div className="transactionDetails">
          <DetailRow label="Тип" value={transfer ? (incoming ? 'Входящий перевод' : 'Исходящий перевод') : operationTypeLabel(tx.transaction_type)} />
          <DetailRow label="Счёт" value={tx.account_name || tx.account_id} />
          {!transfer && <DetailRow label="Категория" value={tx.category_name || tx.category_id} />}
          <DetailRow label="Валюта" value={amountCurrency} />
          <DetailRow label="Дата" value={String(tx.transaction_date || '').replace('T', ' ').slice(0, 16)} />
          <DetailRow label="Описание" value={tx.description} />
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
  const [openActionsId, setOpenActionsId] = useState(null)
  const groupList = groups || (() => {
    const byDate = new Map()
    ;(transactions || []).forEach((tx) => {
      const key = String(tx.transaction_date || '').slice(0, 10)
      if (!byDate.has(key)) byDate.set(key, [])
      byDate.get(key).push(tx)
    })
    return [...byDate.entries()]
  })()

  return (
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
                    actionsOpen={openActionsId === id}
                    onExpand={() => setExpandedId((current) => current === id ? null : id)}
                    onActionsOpen={() => setOpenActionsId(id)}
                    onActionsClose={() => setOpenActionsId((current) => current === id ? null : current)}
                    onDeleted={onDeleted}
                  />
                )
              })}
            </div>
          </section>
        ))}
      </div>
    </section>
  )
}
