import { useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { hierarchyOptions } from './hierarchy-options.js'
import { currencyOptions as buildCurrencyOptions } from './reference-options.js'
import { SmartSelect } from './SmartSelect.jsx'
import { updateReceiptCurrency, updateReceiptItemCategory } from './api.js'

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function receiptAmount(value, currency) {
  const formatted = new Intl.NumberFormat('ru-RU', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(Number(value || 0))
  return `${formatted} ${String(currency || '').toUpperCase()}`.trim()
}

function receiptDateTime(value, fallbackDate) {
  const raw = value || fallbackDate
  if (!raw) return 'Дата и время не распознаны'
  const date = new Date(raw)
  if (Number.isNaN(date.getTime())) return String(raw)
  return new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(date).replace(',', ' ·')
}

export default function ReceiptModal({ transaction = {}, receipt: initialReceipt, reference = {}, onClose, onChanged }) {
  const [receipt, setReceipt] = useState(initialReceipt)
  const [busy, setBusy] = useState('')
  const currency = String(receipt?.currency || transaction.currency_original || 'EUR').toUpperCase()
  const categories = reference?.categories || []

  const categoryOptions = useMemo(() => {
    const expenseCategories = categories.filter((item) => {
      const flow = String(item?.flow_type || '').toLowerCase()
      return !flow || flow === 'expense'
    })
    return [
      { value: '', label: 'Без категории', secondary: 'Не классифицировать', depth: 0 },
      ...hierarchyOptions(expenseCategories, {
        id: (item) => item?.id,
        parent: (item) => item?.parent_id ?? item?.parent_category_id ?? null,
        children: (item) => item?.children || item?.categories || [],
        label: (item) => item?.name || item?.code || 'Категория',
        secondary: (item) => item?.code && item?.name && item.code !== item.name ? item.code : '',
      }),
    ]
  }, [categories])

  const currencyOptions = useMemo(
    () => buildCurrencyOptions(reference?.currencies || [], [], currency),
    [currency, reference?.currencies],
  )

  const changeCurrency = async (value) => {
    const next = String(value || '').toUpperCase()
    if (!next || next === currency || busy) return
    setBusy('currency')
    try {
      const result = await updateReceiptCurrency(receipt.id, next)
      setReceipt((current) => ({ ...current, currency: result?.currency || next }))
      await onChanged?.({ type: 'currency', receiptId: receipt.id, result })
    } catch (error) {
      showError(error?.message || 'Не удалось изменить валюту чека')
    } finally {
      setBusy('')
    }
  }

  const changeCategory = async (item, value) => {
    const categoryId = value ? Number(value) : null
    const key = `item:${item.id}`
    if (busy) return
    setBusy(key)
    try {
      const result = await updateReceiptItemCategory(item.id, categoryId)
      const option = categoryOptions.find((candidate) => String(candidate.value) === String(value))
      setReceipt((current) => ({
        ...current,
        items: (current?.items || []).map((currentItem) => currentItem.id === item.id ? {
          ...currentItem,
          category_id: result?.category_id ?? categoryId,
          category_name: result?.category_name ?? option?.label ?? null,
          category_code: result?.category_code ?? option?.source?.code ?? null,
        } : currentItem),
      }))
      await onChanged?.({ type: 'category', receiptItemId: item.id, result })
    } catch (error) {
      showError(error?.message || 'Не удалось изменить категорию')
    } finally {
      setBusy('')
    }
  }

  const items = receipt?.items || []

  return createPortal(
    <div className="receiptModalBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose?.()}>
      <section className="receiptModalSheet" role="dialog" aria-modal="true" aria-label={`Чек ${receipt?.shop_name || transaction.description || ''}`.trim()}>
        <header className="receiptModalHeader">
          <button type="button" className="receiptModalClose" onClick={onClose} aria-label="Закрыть">×</button>
          <div className="receiptMerchant">{receipt?.shop_name || transaction.description || 'Чек'}</div>
          <div className="receiptDate">{receiptDateTime(receipt?.transaction_date || transaction.transaction_date, receipt?.receipt_date)}</div>
          <div className="receiptTotal">{receiptAmount(receipt?.total_amount ?? transaction.amount_original, currency)}</div>
          <SmartSelect
            className="receiptCurrencySelect"
            value={currency}
            options={currencyOptions}
            onChange={changeCurrency}
            title="Валюта чека"
            disabled={busy === 'currency'}
          />
        </header>

        <div className="receiptPerforation" aria-hidden="true">· · · · · · · · · · · · · · · · · ·</div>

        <div className="receiptItems" role="list">
          {items.length === 0 && <div className="receiptEmpty">Позиции чека не распознаны</div>}
          {items.map((item) => (
            <article className="receiptItem" key={item.id} role="listitem">
              <div className="receiptItemLine">
                <span className="receiptItemDescription">{item.description || item.item_name_original || 'Без описания'}</span>
                <strong className="receiptItemAmount">{receiptAmount(item.amount, currency)}</strong>
              </div>
              <SmartSelect
                className="receiptCategorySelect"
                value={item.category_id == null ? '' : String(item.category_id)}
                options={categoryOptions}
                onChange={(value) => changeCategory(item, value)}
                title={`Категория: ${item.description || item.item_name_original || 'позиция'}`}
                placeholder="Без категории"
                disabled={busy === `item:${item.id}`}
              />
            </article>
          ))}
        </div>

        <footer className="receiptModalFooter">
          <div className="receiptFooterTotal"><span>ИТОГО</span><strong>{receiptAmount(receipt?.total_amount ?? transaction.amount_original, currency)}</strong></div>
          <button type="button" className="receiptDone" onClick={onClose}>Готово</button>
        </footer>
      </section>
    </div>,
    document.body,
  )
}
