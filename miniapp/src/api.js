const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

async function request(path, signal, { allowEmpty = false } = {}) {
  const response = await fetch(`${API_BASE}/${path}`, {
    method: 'GET',
    headers: {
      Accept: 'application/json',
      'X-Telegram-Init-Data': telegramInitData(),
    },
    signal,
  })

  const body = await response.text()

  if (!response.ok) {
    throw new Error(`API ${response.status}${body ? `: ${body.slice(0, 120)}` : ''}`)
  }

  if (!body.trim()) {
    if (allowEmpty) return null
    throw new Error(`Пустой ответ API: ${path}`)
  }

  let payload
  try {
    payload = JSON.parse(body)
  } catch {
    throw new Error(`Некорректный JSON API: ${path}`)
  }

  if (payload?.error) throw new Error(payload.error)
  return payload?.data ?? payload
}

export function getDashboard(signal) {
  return request('api/v1/dashboard', signal)
}

export async function getAccounts(signal) {
  const payload = await request('api/v1/accounts', signal, { allowEmpty: true })
  return payload ?? { accounts: [] }
}

export async function getTransactionReference(signal) {
  const payload = await request('api/v1/transaction-reference', signal, { allowEmpty: true })
  return payload ?? { currencies: [], categories: [] }
}

export async function deleteTransaction(id) {
  const response = await fetch(`${API_BASE}/api/v1/transaction?id=${encodeURIComponent(id)}`, {
    method: 'DELETE',
    headers: {
      Accept: 'application/json',
      'X-Telegram-Init-Data': telegramInitData(),
    },
  })

  const body = await response.text()
  if (!response.ok) {
    throw new Error(`Удаление недоступно: API ${response.status}${body ? ` — ${body.slice(0, 120)}` : ''}`)
  }

  if (!body.trim()) return null
  try {
    const payload = JSON.parse(body)
    if (payload?.error) throw new Error(payload.error)
    return payload?.data ?? payload
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error('Некорректный ответ API при удалении', { cause: error })
    }
    throw error
  }
}

export function getTransactions(
  { accountId, dateFrom, dateTo, includeDescendants = true },
  signal,
) {
  const params = new URLSearchParams({
    account_id: String(accountId),
    date_from: dateFrom,
    date_to: dateTo,
    include_descendants: String(includeDescendants),
  })

  return request(`api/v1/transactions?${params.toString()}`, signal)
}

export function getAccountsExplorerSummary(
  excludedAccountIds = [],
  dateFrom,
  dateTo,
  signal,
) {
  const params = new URLSearchParams({
    date_from: dateFrom,
    date_to: dateTo,
  })

  if (excludedAccountIds.length) {
    params.set('excluded_account_ids', excludedAccountIds.join(','))
  }

  return request(`api/v1/accounts-explorer-summary?${params.toString()}`, signal)
}
