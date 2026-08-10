const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

function errorCode(payload) {
  if (!payload) return ''
  if (typeof payload.error === 'string') return payload.error
  return payload.error?.code || payload.code || ''
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
  let payload = null
  if (responseBody.trim()) {
    try {
      payload = JSON.parse(responseBody)
    } catch {
      if (!response.ok) throw new Error(`API ${response.status}: ${responseBody.slice(0, 120)}`)
      throw new Error(`Некорректный JSON API: ${path}`)
    }
  }

  if (!response.ok) {
    const code = errorCode(payload)
    throw new Error(code || `API ${response.status}${responseBody ? `: ${responseBody.slice(0, 120)}` : ''}`)
  }

  if (!responseBody.trim()) {
    if (allowEmpty) return null
    throw new Error(`Пустой ответ API: ${path}`)
  }

  const code = errorCode(payload)
  if (code) throw new Error(code)
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

export function deleteTransaction(id, signal) {
  return request(`api/v1/transaction?id=${encodeURIComponent(id)}`, signal, {
    method: 'DELETE',
    allowEmpty: true,
  })
}

export function getTransactions({
  accountId,
  dateFrom,
  dateTo,
  includeDescendants = true,
  selectedAccountIds = null,
  incomeCategoryIds = null,
  expenseCategoryIds = null,
}, signal) {
  const params = new URLSearchParams({
    account_id: String(accountId),
    date_from: dateFrom,
    date_to: dateTo,
    include_descendants: String(includeDescendants),
  })
  setOptionalIdFilter(params, 'selected_account_ids', selectedAccountIds)
  setOptionalIdFilter(params, 'income_category_ids', incomeCategoryIds)
  setOptionalIdFilter(params, 'expense_category_ids', expenseCategoryIds)
  return request(`api/v1/transactions?${params.toString()}`, signal)
}

export function getAccountsExplorerSummary({
  selectedAccountIds = [],
  dateFrom,
  dateTo,
  incomeCategoryIds = null,
  expenseCategoryIds = null,
}, signal) {
  const params = new URLSearchParams({
    date_from: dateFrom,
    date_to: dateTo,
  })
  setOptionalIdFilter(params, 'selected_account_ids', selectedAccountIds)
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

export function createAccount({ name, code, accountType, currencyCode, parentId = null }, signal) {
  return request('api/v1/accounts', signal, {
    method: 'POST',
    body: {
      name,
      code,
      account_type: accountType,
      currency_code: currencyCode,
      parent_id: parentId == null ? null : Number(parentId),
    },
  })
}

export function copyAccount(accountId, signal) {
  return request('api/v1/accounts/copy', signal, {
    method: 'POST',
    body: { account_id: Number(accountId) },
  })
}

export function editAccount({ accountId, name, accountType }, signal) {
  return request('api/v1/accounts', signal, {
    method: 'PATCH',
    body: {
      account_id: Number(accountId),
      name,
      account_type: accountType,
    },
  })
}

export function moveAccount(accountId, parentId, signal) {
  return request('api/v1/accounts/move', signal, {
    method: 'POST',
    body: {
      account_id: Number(accountId),
      parent_id: parentId == null ? null : Number(parentId),
    },
  })
}

export function archiveAccount(accountId, signal) {
  return request('api/v1/accounts/archive', signal, {
    method: 'POST',
    body: { account_id: Number(accountId) },
  })
}

export function restoreAccount(accountId, signal) {
  return request('api/v1/accounts/restore', signal, {
    method: 'POST',
    body: { account_id: Number(accountId) },
  })
}

export function previewMoveAccountOperations(sourceAccountId, targetAccountId, signal) {
  return request('api/v1/accounts/move-operations/preview', signal, {
    method: 'POST',
    body: {
      source_account_id: Number(sourceAccountId),
      target_account_id: Number(targetAccountId),
    },
  })
}

export function moveAccountOperations(sourceAccountId, targetAccountId, signal) {
  return request('api/v1/accounts/move-operations', signal, {
    method: 'POST',
    body: {
      source_account_id: Number(sourceAccountId),
      target_account_id: Number(targetAccountId),
    },
  })
}

export function deleteAccount(accountId, signal) {
  return request(`api/v1/accounts?id=${encodeURIComponent(accountId)}`, signal, {
    method: 'DELETE',
    allowEmpty: true,
  })
}
