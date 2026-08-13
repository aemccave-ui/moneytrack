import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { getAccounts, updateReceiptAccounting, updateReceiptItemCategory } from './api.js'
import { hierarchyOptions } from './hierarchy-options.js'
import { currencyOptions as buildCurrencyOptions } from './reference-options.js'
import { SmartSelect } from './SmartSelect.jsx'

const idOf = (item) => item?.id ?? item?.account_id
const parentOf = (item) => item?.parent_id ?? item?.parent_account_id ?? item?.account_parent_id ?? null

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
  const [accounts, setAccounts] = useState([])
  const [accountsLoading, setAccountsLoading] = useState(true)
  const currentCurrency = String(receipt?.currency || transaction.currency_original || 'EUR').toUpperCase()
  const currentAccountId = String(receipt?.account_id ?? transaction.account_id ?? '')
  const [draftCurrency, setDraftCurrency] = useState(currentCurrency)
  const [draftAccountId, setDraftAccountId] = useState(currentAccountId)
  const categories = reference?.categories || []

  useEffect(() => {
    const controller = new AbortController()
    getAccounts(controller.signal)
      .then((payload) => setAccounts(payload?.accounts || payload?.items || []))
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить счета')
      })
      .finally(() => setAccountsLoading(false))
    return () => controller.abort()
  }, [])

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

  const accountOptions = useMemo(() => hierarchyOptions(accounts, {
    id: idOf,
    parent: parentOf,
    children: (item) => item?.children || item?.accounts || [],
    label: (item) => item?.name || item?.code || 'Счёт',
    secondary: (item) => [item?.account_type, item?.currency_code].filter(Boolean).join(' · '),
    disabled: (item, node) => (node.children?.length || 0) > 0,
  }), [accounts])

  const currencyOptions = useMemo(() => buildCurrencyOptions(
    reference?.currencies || [],
    accounts,
    [currentCurrency, draftCurrency],
  ), [reference?.currencies, accounts, currentCurrency, draftCurrency])

  const selectedAccount = useMemo(() => accounts.find((account) => String(idOf(account)) === String(draftAccountId)), [accounts, draftAccountId])
  const selectedAccountCurrency = String(selectedAccount?.currency_code || '').toUpperCase()
  const accountingMismatch = Boolean(draftAccountId && selectedAccountCurrency && selectedAccountCurrency !== draftCurrency)
  const accountingChanged = String(draftAccountId) !== String(currentAccountId) || draftCurrency !== currentCurrency

  const saveAccounting = async () => {
    if (!accountingChanged || accountingMismatch || !draftAccountId || !draftCurrency || busy) return
    setBusy('accounting')
    try {
      const result = await updateReceiptAccounting(receipt.id, draftAccountId, draftCurrency)
      const updated = result?.receipt || result || {}
      const next = {
        ...receipt,
        ...updated,
        account_id: updated.account_id ?? Number(draftAccountId),
        account_name: updated.account_name ?? selectedAccount?.name ?? receipt.account_name,
        account_currency: updated.account_currency ?? selectedAccountCurrency,
        currency: updated.currency ?? draftCurrency,
      }
      setReceipt(next)
      onChanged?.(next)
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить счёт и валюту чека')
    } finally {
      setBusy('')
    }
  }

  const changeItemCategory = async (item, value) => {
    if (busy) return
    setBusy(`item-${item.id}`)
    try {
      const result = await updateReceiptItemCategory(item.id, value || null)
      const updated = result?.item || result || {}
      const nextItems = (receipt.items || []).map((current) => (
        String(current.id) === String(item.id)
          ? {
              ...current,
              ...updated,
              category_id: updated.category_id ?? (value ? Number(value) : null),
              category_name: updated.category_name ?? categoryOptions.find((option) => String(option.value) === String(value))?.label ?? null,
            }
          : current
      ))
      const next = { ...receipt, items: nextItems }
      setReceipt(next)
      onChanged?.(next)
    } catch (error) {
      showError(error?.message || 'Не удалось изменить категорию позиции')
    } finally {
      setBusy('')
    }
  }

  return createPortal(
    <div className="receiptModalBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose?.()}>
      <section className="receiptModal" role="dialog" aria-modal="true" aria-label="Чек">
        <header className="receiptModalHeader">
          <div>
            <span>Чек</span>
            <strong>{receipt.shop_name || transaction.description || 'Магазин не распознан'}</strong>
          </div>
          <button type="button" onClick={onClose} aria-label="Закрыть">×</button>
        </header>

        <div className="receiptModalMeta">
          <div><span>Дата и время</span><strong>{receiptDateTime(receipt.transaction_date, receipt.receipt_date)}</strong></div>
          <div><span>Итого</span><strong>{receiptAmount(receipt.total_amount ?? transaction.amount_original, receipt.currency || transaction.currency_original)}</strong></div>
        </div>

        <section className="receiptAccountingCard">
          <div className="receiptAccountingField">
            <label htmlFor="receipt-account">Счёт учёта</label>
            <SmartSelect
              id="receipt-account"
              value={draftAccountId}
              options={accountOptions}
              onChange={setDraftAccountId}
              placeholder={accountsLoading ? 'Загрузка…' : 'Выберите счёт'}
              disabled={accountsLoading || busy === 'accounting'}
            />
          </div>
          <div className="receiptAccountingField">
            <label htmlFor="receipt-currency">Валюта</label>
            <SmartSelect
              id="receipt-currency"
              value={draftCurrency}
              options={currencyOptions}
              onChange={setDraftCurrency}
              placeholder="Выберите валюту"
              disabled={busy === 'accounting'}
            />
          </div>
          {accountingMismatch && (
            <div className="receiptAccountingMismatch" role="alert">
              Валюта счёта {selectedAccountCurrency} не совпадает с валютой чека {draftCurrency}. Выберите счёт в {draftCurrency} или измените валюту.
            </div>
          )}
          <button
            type="button"
            className="receiptAccountingSave"
            onClick={saveAccounting}
            disabled={!accountingChanged || accountingMismatch || !draftAccountId || !draftCurrency || busy === 'accounting'}
          >
            {busy === 'accounting' ? 'Сохраняю…' : 'Сохранить счёт и валюту'}
          </button>
        </section>

        <div className="receiptItemsHeader">
          <span>Позиция</span><span>Категория</span><span>Сумма</span>
        </div>
        <div className="receiptItemsList">
          {(receipt.items || []).map((item) => (
            <div className="receiptItemRow" key={item.id}>
              <div className="receiptItemName">
                <strong>{item.description || item.item_name_original || 'Позиция'}</strong>
                {Number(item.quantity || 1) !== 1 && <small>{item.quantity} × {receiptAmount(item.unit_price, receipt.currency)}</small>}
              </div>
              <SmartSelect
                value={item.category_id == null ? '' : String(item.category_id)}
                options={categoryOptions}
                onChange={(value) => changeItemCategory(item, value)}
                placeholder="Без категории"
                disabled={busy === `item-${item.id}`}
                aria-label={`Категория ${item.description || item.item_name_original || item.id}`}
              />
              <strong className="receiptItemAmount">{receiptAmount(item.amount, receipt.currency)}</strong>
            </div>
          ))}
          {!(receipt.items || []).length && <div className="receiptItemsEmpty">Позиции чека не распознаны.</div>}
        </div>
      </section>
    </div>,
    document.body,
  )
}
