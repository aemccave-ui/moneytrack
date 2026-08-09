const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

async function request(path, signal, {
  allowEmpty = false,
  method = 'GET',
  body = undefined,
} = {}) {
  const headers = {
    Accept: 'application/json',
    'X-Telegram-Init-Data': telegramInitData(),
  }
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const response = await fetch(`${API_BASE}/${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal,
  })

  const responseBody = await response.text()

  if (!response.ok) {
    throw new Error(`API ${response.status}${responseBody ? `: ${responseBody.slice(0, 120)}` : ''}`)
  }

  if (!responseBody.trim()) {
    if (allowEmpty) return null
    throw new Error(`Пустой ответ API: ${path}`)
  }

  let payload
  try {
    payload = JSON.parse(responseBody)
  } catch {
    throw new Error(`Некорректный JSON API: ${path}`)
  }

  if (payload?.error) throw new Error(payload.error)
  return payload?.data ?? payload
}

function setOptionalIdFilter(params, key, ids) {
  if (ids == null) return
  params.set(key, ids.map(String).join(','))
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
  {
    accountId,
    dateFrom,
    dateTo,
    includeDescendants = true,
    incomeCategoryIds = null,
    expenseCategoryIds = null,
  },
  signal,
) {
  const params = new URLSearchParams({
    account_id: String(accountId),
    date_from: dateFrom,
    date_to: dateTo,
    include_descendants: String(includeDescendants),
  })

  setOptionalIdFilter(params, 'income_category_ids', incomeCategoryIds)
  setOptionalIdFilter(params, 'expense_category_ids', expenseCategoryIds)

  return request(`api/v1/transactions?${params.toString()}`, signal)
}

export function getAccountsExplorerSummary(
  {
    excludedAccountIds = [],
    dateFrom,
    dateTo,
    incomeCategoryIds = null,
    expenseCategoryIds = null,
  },
  signal,
) {
  const params = new URLSearchParams({
    date_from: dateFrom,
    date_to: dateTo,
  })

  if (excludedAccountIds.length) {
    params.set('excluded_account_ids', excludedAccountIds.join(','))
  }

  setOptionalIdFilter(params, 'income_category_ids', incomeCategoryIds)
  setOptionalIdFilter(params, 'expense_category_ids', expenseCategoryIds)

  return request(`api/v1/accounts-explorer-summary?${params.toString()}`, signal)
}

export async function getFilterPresets(signal) {
  const payload = await request('api/v1/filter-presets', signal, { allowEmpty: true })
  return payload ?? { presets: [] }
}

export function createFilterPreset({ name, accountIds, incomeCategoryIds, expenseCategoryIds }, signal) {
  return request('api/v1/filter-presets', signal, {
    method: 'POST',
    body: {
      name,
      account_ids: accountIds.map(Number),
      income_category_ids: incomeCategoryIds.map(Number),
      expense_category_ids: expenseCategoryIds.map(Number),
    },
  })
}

export function renameFilterPreset(id, name, signal) {
  return request('api/v1/filter-presets', signal, {
    method: 'PATCH',
    body: { id: Number(id), name },
  })
}

export function deleteFilterPreset(id, signal) {
  return request(`api/v1/filter-presets?id=${encodeURIComponent(id)}`, signal, {
    method: 'DELETE',
    allowEmpty: true,
  })
}
