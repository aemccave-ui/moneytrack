import { useEffect, useMemo, useState } from 'react'
import { createPortal } from 'react-dom'
import { getAccounts, updateReceiptItemCategory } from './api.js'
import { updateReceiptAccounting } from './receipt-accounting-api.js'
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
    label: (item) => item?.name || 'Счёт',
    secondary: (item) => String(item?.currency_code || '').toUpperCase(),
    disabled: (_item, children) => children.length > 0,
  }), [accounts])

  const selectedAccount = useMemo(
    () => accountOptions.find((option) => String(option.value) === String(draftAccountId))?.source || null,
    [accountOptions, draftAccountId],
  )
  const selectedAccountCurrency = String(selectedAccount?.currency_code || '').toUpperCase()
  const accountingConsistent = Boolean(selectedAccount && draftCurrency && selectedAccountCurrency === draftCurrency)
  const accountingDirty = draftCurrency !== currentCurrency || draftAccountId !== currentAccountId

  const usedAccountCurrencies = useMemo(
    () => accountOptions.map((option) => option?.source?.currency_code).filter(Boolean),
    [accountOptions],
  )
  const currencyOptions = useMemo(
    () => buildCurrencyOptions(reference?.currencies || [], usedAccountCurrencies, draftCurrency),
    [draftCurrency, reference?.currencies, usedAccountCurrencies],
  )

  const saveAccounting = async () => {
    if (!accountingDirty || busy || accountsLoading) return
    if (!accountingConsistent) {
      showError(`Валюта чека ${draftCurrency} должна совпадать с валютой счёта ${selectedAccountCurrency || '—'}.`)
      return
    }
    setBusy('accounting')
    try {
      const result = await updateReceiptAccounting(receipt.id, Number(draftAccountId), draftCurrency)
      setReceipt((current) => ({
        ...current,
        currency: result?.currency || draftCurrency,
        account_id: result?.account_id ?? Number(draftAccountId),
        account_name: result?.account_name ?? selectedAccount?.name ?? current?.account_name,
        account_currency: result?.account_currency || draftCurrency,
      }))
      await onChanged?.({ type: 'currency', accounting: true, receiptId: receipt.id, result })
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить счёт и валюту чека')
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
  const displayedCurrency = draftCurrency || currentCurrency
  const finish = () => accountingDirty ? saveAccounting() : onClose?.()

  return createPortal(
    <div className="receiptModalBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose?.()}>
      <section className="receiptModalSheet" role="dialog" aria-modal="true" aria-label={`Чек ${receipt?.shop_name || transaction.description || ''}`.trim()}>
        <header className="receiptModalHeader">
          <button type="button" className="receiptModalClose" onClick={onClose} aria-label="Закрыть">×</button>
          <div className="receiptMerchant">{receipt?.shop_name || transaction.description || 'Чек'}</div>
          <div className="receiptDate">{receiptDateTime(receipt?.transaction_date || transaction.transaction_date, receipt?.receipt_date)}</div>
          <div className="receiptTotal">{receiptAmount(receipt?.total_amount ?? transaction.amount_original, displayedCurrency)}</div>
          <div className="receiptAccountingControls">
            <SmartSelect
              className="receiptAccountSelect"
              label="Счёт учёта"
              value={draftAccountId}
              options={accountOptions}
              onChange={setDraftAccountId}
              title="Счёт учёта чека"
              placeholder="Выбрать счёт"
              disabled={accountsLoading || busy === 'accounting'}
            />
            <SmartSelect
              className="receiptCurrencySelect"
              label="Валюта"
              value={draftCurrency}
              options={currencyOptions}
              onChange={(value) => setDraftCurrency(String(value || '').toUpperCase())}
              title="Валюта чека"
              disabled={busy === 'accounting'}
            />
          </div>
          {!accountsLoading && selectedAccount && !accountingConsistent && (
            <div className="receiptAccountingMismatch" role="alert">
              Валюта чека {draftCurrency} не совпадает с валютой счёта {selectedAccountCurrency}.
            </div>
          )}
        </header>

        <div className="receiptPerforation" aria-hidden="true">· · · · · · · · · · · · · · · · · ·</div>

        <div className="receiptItems" role="list">
          {items.length === 0 && <div className="receiptEmpty">Позиции чека не распознаны</div>}
          {items.map((item) => (
            <article className="receiptItem" key={item.id} role="listitem">
              <div className="receiptItemLine">
                <span className="receiptItemDescription">{item.description || item.item_name_original || 'Без описания'}</span>
                <strong className="receiptItemAmount">{receiptAmount(item.amount, displayedCurrency)}</strong>
              </div>
              <SmartSelect
                className="receiptCategorySelect"
                value={item.category_id == null ? '' : String(item.category_id)}
                options={categoryOptions}
                onChange={(value) => changeCategory(item, value)}
                title={`Категория: ${item.description || item.item_name_original || 'позиция'}`}
                placeholder="Без категории"
                disabled={busy === `item:${item.id}` || busy === 'accounting'}
              />
            </article>
          ))}
        </div>

        <footer className="receiptModalFooter">
          <div className="receiptFooterTotal"><span>ИТОГО</span><strong>{receiptAmount(receipt?.total_amount ?? transaction.amount_original, displayedCurrency)}</strong></div>
          <button
            type="button"
            className="receiptDone"
            onClick={finish}
            disabled={Boolean(busy) || (accountingDirty && (!accountingConsistent || accountsLoading))}
          >
            {busy === 'accounting' ? 'Сохранение…' : accountingDirty ? 'Сохранить' : 'Готово'}
          </button>
        </footer>
      </section>
    </div>,
    document.body,
  )
}
