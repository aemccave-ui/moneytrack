import { MoneyTrackApiError } from './api-errors.js'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

export async function updateReceiptAccounting(receiptId, accountId, currency, signal) {
  const response = await fetch(`${API_BASE}/api/v1/receipt/accounting`, {
    method: 'PATCH',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'X-Telegram-Init-Data': window.Telegram?.WebApp?.initData || '',
    },
    body: JSON.stringify({
      receipt_id: Number(receiptId),
      account_id: Number(accountId),
      currency: String(currency || '').toUpperCase(),
    }),
    signal,
  })

  const text = await response.text()
  let payload = null
  if (text.trim()) {
    try {
      payload = JSON.parse(text)
    } catch {
      throw new MoneyTrackApiError(`HTTP_${response.status}`, text.slice(0, 120), response.status)
    }
  }

  if (!response.ok || payload?.ok === false) {
    const code = payload?.error?.code || payload?.code || `HTTP_${response.status}`
    const message = payload?.error?.message || payload?.message || ''
    throw new MoneyTrackApiError(code, message, response.status)
  }

  return payload?.data ?? payload
}
