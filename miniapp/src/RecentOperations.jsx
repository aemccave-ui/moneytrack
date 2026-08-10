import { useEffect, useRef, useState } from 'react'
import { deleteTransaction } from './api.js'

const ACTION_REVEAL = 176
const SWIPE_THRESHOLD = 28

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
  const rowRef = useRef(null)
  const gesture = useRef({ startX: 0, startY: 0, dx: 0, dy: 0, axis: null, active: false, pointerId: null, swiped: false })
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

  const beginGesture = (clientX, clientY) => {
    gesture.current.startX = clientX
    gesture.current.startY = clientY
    gesture.current.dx = 0
    gesture.current.dy = 0
    gesture.current.axis = null
    gesture.current.active = true
    gesture.current.swiped = false
  }

  const moveGesture = (clientX, clientY, preventDefault) => {
    if (!gesture.current.active) return
    const dx = clientX - gesture.current.startX
    const dy = clientY - gesture.current.startY
    gesture.current.dx = dx
    gesture.current.dy = dy

    if (!gesture.current.axis && Math.max(Math.abs(dx), Math.abs(dy)) > 6) {
      gesture.current.axis = Math.abs(dx) > Math.abs(dy) ? 'x' : 'y'
    }
    if (gesture.current.axis !== 'x') return

    preventDefault?.()
    if (dx < 0) {
      if (Math.abs(dx) > 8) gesture.current.swiped = true
      setDragX(Math.max(-ACTION_REVEAL, dx))
    } else {
      setDragX(0)
    }
  }

  const finishGesture = () => {
    if (!gesture.current.active) return
    const shouldOpen = gesture.current.axis === 'x' && gesture.current.dx < -SWIPE_THRESHOLD
    gesture.current.active = false
    if (shouldOpen) {
      gesture.current.swiped = true
      setDragX(0)
      onActionsOpen()
    } else {
      setDragX(0)
      if (actionsOpen) onActionsClose()
    }
    gesture.current.dx = 0
    gesture.current.dy = 0
    gesture.current.axis = null
  }

  const cancelGesture = () => {
    gesture.current.active = false
    gesture.current.dx = 0
    gesture.current.dy = 0
    gesture.current.axis = null
    gesture.current.swiped = false
    setDragX(0)
  }

  const pointerDown = (event) => {
    if (event.pointerType === 'touch') return
    if (event.button != null && event.button !== 0) return
    beginGesture(event.clientX, event.clientY)
    gesture.current.pointerId = event.pointerId
    event.currentTarget.setPointerCapture?.(event.pointerId)
  }

  const pointerMove = (event) => {
    if (event.pointerType === 'touch') return
    moveGesture(event.clientX, event.clientY, () => event.preventDefault())
  }

  const releasePointer = (event) => {
    if (gesture.current.pointerId != null && event.currentTarget.hasPointerCapture?.(gesture.current.pointerId)) {
      event.currentTarget.releasePointerCapture(gesture.current.pointerId)
    }
    gesture.current.pointerId = null
  }

  const pointerUp = (event) => {
    if (event.pointerType === 'touch') return
    releasePointer(event)
    finishGesture()
  }

  const pointerCancel = (event) => {
    if (event.pointerType === 'touch') return
    releasePointer(event)
    cancelGesture()
  }

  useEffect(() => {
    const row = rowRef.current
    if (!row) return undefined

    const start = (event) => {
      if (event.touches.length !== 1) return
      const touch = event.touches[0]
      beginGesture(touch.clientX, touch.clientY)
    }
    const move = (event) => {
      const touch = event.touches[0]
      if (!touch) return
      moveGesture(touch.clientX, touch.clientY, () => event.preventDefault())
    }
    const end = () => finishGesture()
    const cancel = () => cancelGesture()

    row.addEventListener('touchstart', start, { passive: true })
    row.addEventListener('touchmove', move, { passive: false })
    row.addEventListener('touchend', end, { passive: true })
    row.addEventListener('touchcancel', cancel, { passive: true })
    return () => {
      row.removeEventListener('touchstart', start)
      row.removeEventListener('touchmove', move)
      row.removeEventListener('touchend', end)
      row.removeEventListener('touchcancel', cancel)
    }
  })

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
      <div className={`transactionSwipeShell ${actionsOpen ? 'actionsOpen' : ''} ${dragX < 0 ? 'isSwiping' : ''}`}>
        <div className="transactionSwipeActions" aria-hidden={!actionsOpen && dragX >= 0}>
          <button type="button" disabled={transfer} onClick={() => showInfo('Повтор операции будет подключён отдельным write-contract.')}>Повторить</button>
          <button type="button" disabled={transfer} onClick={() => showInfo('Редактирование операции будет подключено отдельным write-contract.')}>Изменить</button>
          <button type="button" className="danger" disabled={transfer} onClick={remove}>Удалить</button>
        </div>
        <button
          ref={rowRef}
          type="button"
          className="transactionRow"
          style={{ transform: `translateX(${actionsOpen ? -ACTION_REVEAL : dragX}px)` }}
          onPointerDown={pointerDown}
          onPointerMove={pointerMove}
          onPointerUp={pointerUp}
          onPointerCancel={pointerCancel}
          onClick={(event) => {
            if (gesture.current.swiped) {
              event.preventDefault()
              gesture.current.swiped = false
              return
            }
            if (!actionsOpen) onExpand()
          }}
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
