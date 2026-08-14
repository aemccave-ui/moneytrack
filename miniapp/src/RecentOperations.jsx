import { useEffect, useMemo, useRef, useState } from 'react'
import { deleteTransaction, deleteTransfer, getReceiptByTransaction, getTransactionReference } from './api.js'
import { operationSourceKind } from './operation-source.jsx'
import ReceiptModal from './ReceiptModal.jsx'
import { SwipeReveal } from './SwipeReveal.jsx'
import TransactionEditor from './TransactionEditor.jsx'
import TransferEditor from './TransferEditor.jsx'

let referencePromise = null

function loadTransactionReference() {
  if (!referencePromise) {
    referencePromise = getTransactionReference().catch((error) => {
      referencePromise = null
      throw error
    })
  }
  return referencePromise
}

function transferIdOf(tx) {
  if (tx?.transfer_id != null) return Number(tx.transfer_id)
  const match = String(tx?.id || '').match(/^transfer-(\d+)$/)
  return match ? Number(match[1]) : null
}

const operationTypeLabel = (type) => ({ income: 'Доход', expense: 'Расход', openingbalance: 'Начальный остаток', adjustment: 'Корректировка', transfer: 'Перевод' }[type] || type || 'Операция')

function DeleteIcon() {
  return <svg className="swipeActionIcon" viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7h14M9 7V4h6v3M8 10v7M12 10v7M16 10v7M6 7l1 13h10l1-13" /></svg>
}

function confirmAction(message) {
  if (window.Telegram?.WebApp?.showConfirm) return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  return Promise.resolve(window.confirm(message))
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function TransactionRow({ tx, privacy, baseCurrency, money, loadingReceipt, onOpen, onDelete, categoryName }) {
  const transfer = tx.transaction_type === 'transfer'
  const incoming = transfer && tx.transfer_direction === 'incoming'
  const positive = tx.transaction_type === 'income' || incoming
  const amountCurrency = tx.currency_original || tx.currency || baseCurrency
  const rawAmount = Number(tx.amount_original ?? tx.amount ?? 0)
  const amount = positive ? Math.abs(rawAmount) : -Math.abs(rawAmount)
  const actions = [{ key: 'delete', label: 'Удалить', icon: <DeleteIcon />, danger: true, onClick: onDelete }]
  return (
    <article className="transactionCard">
      <SwipeReveal id={`tx:${tx.id}`} actions={actions} actionWidth={56} className="transactionSwipeReveal">
        {({ open }) => <button type="button" className="transactionRow" onClick={() => { if (!open) onOpen() }} aria-busy={loadingReceipt || undefined} aria-label={`${tx.description || operationTypeLabel(tx.transaction_type)}. Нажмите, чтобы открыть. Смахните влево для удаления.`}>
          <span className={`transactionTypeMark ${positive ? 'income' : 'expense'}`} aria-hidden="true">{positive ? '↑' : '↓'}</span>
          <span className="transactionIdentity"><strong>{tx.description || operationTypeLabel(tx.transaction_type)}</strong><small>{loadingReceipt ? 'Открываю чек…' : (tx.account_name || categoryName || tx.category_name || operationTypeLabel(tx.transaction_type))}</small></span>
          <strong className={`transactionAmount ${positive ? 'income' : 'expense'} sensitive`}>{privacy ? '••••' : money(amount, amountCurrency)}</strong>
        </button>}
      </SwipeReveal>
    </article>
  )
}

export function RecentOperations({ groups, transactions, privacy, baseCurrency, money, dayLabel, onDeleted, title = 'Последние операции', emptyLabel = 'Операций пока нет' }) {
  const [editor, setEditor] = useState(null)
  const [busyId, setBusyId] = useState(null)
  const [receiptLoadingId, setReceiptLoadingId] = useState(null)
  const [receiptView, setReceiptView] = useState(null)
  const receiptRefreshPending = useRef(false)
  const [reference, setReference] = useState({ currencies: [], categories: [] })
  const categoryNames = useMemo(() => new Map((reference.categories || []).map((item) => [String(item.id), item.name || item.code || String(item.id)])), [reference.categories])

  useEffect(() => {
    let alive = true
    loadTransactionReference().then((refs) => alive && setReference(refs || { currencies: [], categories: [] })).catch(() => {})
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
    if (transfer && !transferId) { showError('Не удалось определить перевод.'); return }
    if (!(await confirmAction(transfer ? 'Удалить этот перевод целиком?' : 'Удалить эту операцию?'))) return
    setBusyId(tx.id)
    try {
      if (transfer) await deleteTransfer(transferId)
      else await deleteTransaction(tx.id)
      await onDeleted?.(tx)
    } catch (error) {
      showError(error?.message || (transfer ? 'Не удалось удалить перевод' : 'Не удалось удалить операцию'))
    } finally { setBusyId(null) }
  }

  const saved = async () => { await onDeleted?.() }

  const fetchReceipt = async (tx) => {
    const id = String(tx.id)
    if (receiptLoadingId != null) return { blocked: true, receipt: null }
    setReceiptLoadingId(id)
    try { return { blocked: false, receipt: await getReceiptByTransaction(tx.id) } }
    catch (error) { showError(error?.message || 'Не удалось открыть чек'); return { blocked: true, receipt: null } }
    finally { setReceiptLoadingId(null) }
  }

  const openOperation = async (tx) => {
    if (tx.transaction_type === 'transfer') { setEditor({ operation: tx, mode: 'edit', kind: 'transfer' }); return }
    const sourceKind = operationSourceKind(tx)
    if (sourceKind === 'photo_receipt' || sourceKind == null) {
      const lookup = await fetchReceipt(tx)
      if (lookup.blocked) return
      if (lookup.receipt) { receiptRefreshPending.current = false; setReceiptView({ transaction: tx, receipt: lookup.receipt }); return }
      if (sourceKind === 'photo_receipt') { showError('Источник операции — фото чека, но связанный чек не найден.'); return }
    }
    setEditor({ operation: tx, mode: 'edit', kind: 'transaction' })
  }

  const receiptChanged = () => { receiptRefreshPending.current = true }
  const closeReceipt = async () => {
    setReceiptView(null)
    if (!receiptRefreshPending.current) return
    receiptRefreshPending.current = false
    await onDeleted?.()
  }

  return <>
    <section className="section recentOperationsSection">
      <div className="sectionHeader"><h2>{title}</h2></div>
      {!groupList.length && <div className="emptyCard">{emptyLabel}</div>}
      <div className="transactionGroups">{groupList.map(([date, items]) => <section className="transactionGroup" key={date}><h3>{dayLabel ? dayLabel(date) : date}</h3><div className="transactionList">{items.map((tx) => {
        const id = String(tx.id)
        return <TransactionRow key={id} tx={tx} privacy={privacy} baseCurrency={baseCurrency} money={money} loadingReceipt={receiptLoadingId === id} onOpen={() => openOperation(tx)} onDelete={() => remove(tx)} categoryName={tx.category_id == null ? '' : categoryNames.get(String(tx.category_id))} />
      })}</div></section>)}</div>
    </section>
    {receiptView && <ReceiptModal transaction={receiptView.transaction} receipt={receiptView.receipt} reference={reference} onClose={closeReceipt} onChanged={receiptChanged} />}
    {editor?.kind === 'transaction' && <TransactionEditor operation={editor.operation} mode={editor.mode} onClose={() => setEditor(null)} onSaved={saved} />}
    {editor?.kind === 'transfer' && <TransferEditor operation={editor.operation} mode={editor.mode} onClose={() => setEditor(null)} onSaved={saved} />}
    {busyId != null && <div className="transactionBusy" role="status">Удаление…</div>}
  </>
}
