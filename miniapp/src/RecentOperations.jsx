import { useEffect, useRef, useState } from 'react'
import { deleteTransaction } from './api.js'
import { announceSwipeOpen, nextSwipeScope, SWIPE_OPEN_EVENT } from './swipe-coordinator.js'

const TRANSACTION_ACTIONS_WIDTH = 156
const TRANSACTION_OPEN_THRESHOLD = 34

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
  swipeOpen,
  onSwipeOpen,
  onSwipeClose,
  onExpand,
  onDeleted,
}) {
  const shellRef = useRef(null)
  const swipeGesture = useRef({ startX: 0, startY: 0 })
  const transfer = tx.transaction_type === 'transfer'
  const incoming = transfer && tx.transfer_direction === 'incoming'
  const positive = tx.transaction_type === 'income' || incoming
  const amountCurrency = tx.currency_original || tx.currency || baseCurrency
  const rawAmount = Number(tx.amount_original ?? tx.amount ?? 0)
  const amount = positive ? Math.abs(rawAmount) : -Math.abs(rawAmount)

  useEffect(() => {
    const shell = shellRef.current
    if (!shell) return
    const target = swipeOpen ? TRANSACTION_ACTIONS_WIDTH : 0
    if (Math.abs(shell.scrollLeft - target) > 1) {
      shell.scrollTo({ left: target, behavior: 'smooth' })
    }
  }, [swipeOpen])

  useEffect(() => {
    const shell = shellRef.current
    if (!shell) return undefined

    const touchStart = (event) => {
      const touch = event.touches[0]
      if (!touch) return
      swipeGesture.current.startX = touch.clientX
      swipeGesture.current.startY = touch.clientY
    }

    const settle = (event) => {
      const touch = event.changedTouches?.[0]
      const dx = touch ? touch.clientX - swipeGesture.current.startX : 0
      const dy = touch ? touch.clientY - swipeGesture.current.startY : 0
      const horizontal = Math.abs(dx) > Math.abs(dy) * 1.05
      const explicitOpen = horizontal && dx < -24
      const explicitClose = horizontal && dx > 18
      const shouldOpen = !explicitClose && (explicitOpen || shell.scrollLeft >= TRANSACTION_OPEN_THRESHOLD)
      if (shouldOpen) {
        onSwipeOpen?.()
        shell.scrollTo({ left: TRANSACTION_ACTIONS_WIDTH, behavior: 'smooth' })
      } else {
        onSwipeClose?.()
        shell.scrollTo({ left: 0, behavior: 'smooth' })
      }
    }

    const cancel = () => {
      onSwipeClose?.()
      shell.scrollTo({ left: 0, behavior: 'smooth' })
    }

    shell.addEventListener('touchstart', touchStart, { passive: true })
    shell.addEventListener('touchend', settle, { passive: true })
    shell.addEventListener('touchcancel', cancel, { passive: true })
    return () => {
      shell.removeEventListener('touchstart', touchStart)
      shell.removeEventListener('touchend', settle)
      shell.removeEventListener('touchcancel', cancel)
    }
  }, [onSwipeClose, onSwipeOpen])

  const remove = async () => {
    if (transfer) {
      showInfo('Перевод не удаляется через endpoint обычной операции.')
      return
    }
    if (!(await confirmAction('Удалить эту операцию?'))) return
    try {
      await deleteTransaction(tx.id)
      await onDeleted?.(tx)
    } catch (error) {
      showInfo(error?.message || 'Не удалось удалить операцию')
    }
  }

  return (
    <article className={`transactionCard ${expanded ? 'expanded' : ''}`}>
      <div ref={shellRef} className="transactionSwipeShell" aria-label="Смахните строку влево для действий">
        <div className="transactionSwipeTrack">
          <button
            type="button"
            className="transactionRow"
            onClick={(event) => {
              if ((shellRef.current?.scrollLeft || 0) > 4) {
                event.preventDefault()
                return
              }
              onExpand()
            }}
            aria-expanded={expanded}
          >
            <span className={`transactionTypeMark ${positive ? 'income' : 'expense'}`} aria-hidden="true">{positive ? '↑' : '↓'}</span>
            <span className="transactionIdentity"><strong>{tx.description || operationTypeLabel(tx.transaction_type)}</strong><small>{tx.account_name || tx.category_name || operationTypeLabel(tx.transaction_type)}</small></span>
            <strong className={`transactionAmount ${positive ? 'income' : 'expense'} sensitive`}>{privacy ? '••••' : money(amount, amountCurrency)}</strong>
          </button>
          <div className="transactionSwipeActions">
            <button type="button" className="swipeActionButton" disabled={transfer} onClick={() => showInfo('Повтор операции будет подключён отдельным write-contract.')}><SwipeActionIcon name="repeat" /><span>Повторить</span></button>
            <button type="button" className="swipeActionButton" disabled={transfer} onClick={() => showInfo('Редактирование операции будет подключено отдельным write-contract.')}><SwipeActionIcon name="edit" /><span>Изменить</span></button>
            <button type="button" className="swipeActionButton danger" disabled={transfer} onClick={remove}><SwipeActionIcon name="delete" /><span>Удалить</span></button>
          </div>
        </div>
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
  const [openSwipeId, setOpenSwipeId] = useState(null)
  const [swipeScope] = useState(() => nextSwipeScope('operations'))
  const groupList = groups || (() => {
    const byDate = new Map()
    ;(transactions || []).forEach((tx) => {
      const key = String(tx.transaction_date || '').slice(0, 10)
      if (!byDate.has(key)) byDate.set(key, [])
      byDate.get(key).push(tx)
    })
    return [...byDate.entries()]
  })()

  useEffect(() => {
    if (openSwipeId == null) return undefined
    const timer = window.setTimeout(() => setOpenSwipeId(null), 2000)
    return () => window.clearTimeout(timer)
  }, [openSwipeId])

  useEffect(() => {
    const onExternalSwipe = (event) => {
      if (openSwipeId == null) return
      const ownKey = `${swipeScope}:${openSwipeId}`
      if (event.detail?.key !== ownKey) setOpenSwipeId(null)
    }
    window.addEventListener(SWIPE_OPEN_EVENT, onExternalSwipe)
    return () => window.removeEventListener(SWIPE_OPEN_EVENT, onExternalSwipe)
  }, [openSwipeId, swipeScope])

  const openSwipe = (id) => {
    setOpenSwipeId(id)
    announceSwipeOpen(`${swipeScope}:${id}`)
  }

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
                    swipeOpen={openSwipeId === id}
                    onSwipeOpen={() => openSwipe(id)}
                    onSwipeClose={() => setOpenSwipeId((current) => current === id ? null : current)}
                    onExpand={() => setExpandedId((current) => current === id ? null : id)}
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
