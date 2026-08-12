import { MoneyTrackApiError } from './api-errors.js'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

let lastAccountMoveResult = null

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

function errorCode(payload) {
  if (!payload) return ''
  if (typeof payload.error === 'string') return payload.error
  return payload.error?.code || payload.code || ''
}

function errorMessage(payload) {
  if (!payload || typeof payload !== 'object') return ''
  return payload.error?.message || payload.message || ''
}

async function parseResponse(response, { allowText = false } = {}) {
  const responseBody = await response.text()
  if (!responseBody.trim()) return { responseBody, payload: null }
  try {
    return { responseBody, payload: JSON.parse(responseBody) }
  } catch {
    if (allowText && response.ok) return { responseBody, payload: responseBody }
    if (!response.ok) {
      throw new MoneyTrackApiError(`HTTP_${response.status}`, responseBody.slice(0, 120), response.status)
    }
    throw new MoneyTrackApiError('API_RESPONSE_INVALID', 'Сервис вернул некорректный ответ.', response.status)
  }
}

async function request(path, signal, {
  allowEmpty = false,
  allowText = false,
  method = 'GET',
  body = undefined,
  rawBody = undefined,
  headers: extraHeaders = {},
} = {}) {
  const headers = {
    Accept: 'application/json',
    'X-Telegram-Init-Data': telegramInitData(),
    ...extraHeaders,
  }
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const response = await fetch(`${API_BASE}/${path}`, {
    method,
    headers,
    body: rawBody !== undefined ? rawBody : body === undefined ? undefined : JSON.stringify(body),
    signal,
  })

  const { responseBody, payload } = await parseResponse(response, { allowText })

  if (!response.ok) {
    const code = errorCode(payload) || `HTTP_${response.status}`
    throw new MoneyTrackApiError(code, errorMessage(payload), response.status)
  }

  if (!responseBody.trim()) {
    if (allowEmpty) return null
    throw new MoneyTrackApiError('API_RESPONSE_EMPTY', 'Сервис вернул пустой ответ.', response.status)
  }

  if (typeof payload === 'string') return payload
  const code = errorCode(payload)
  if (code) throw new MoneyTrackApiError(code, errorMessage(payload), response.status)
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

export async function getArchivedAccounts(signal) {
  const payload = await request('api/v1/accounts/archived', signal, { allowEmpty: true })
  return payload ?? { accounts: [] }
}

export async function getTransactionReference(signal) {
  const payload = await request('api/v1/transaction-reference', signal, { allowEmpty: true })
  return payload ?? { currencies: [], categories: [] }
}

export function updateCategory({ categoryId, name, flowType }, signal) {
  return request('api/v1/categories', signal, {
    method: 'PATCH',
    body: {
      category_id: Number(categoryId),
      name,
      flow_type: flowType,
    },
  })
}

export function deleteTransaction(id, signal) {
  return request(`api/v1/transaction?id=${encodeURIComponent(id)}`, signal, {
    method: 'DELETE',
    allowEmpty: true,
  })
}

export function createTransaction(payload, signal) {
  return request('api/v1/transaction', signal, { method: 'POST', body: payload })
}

export function updateTransaction(id, payload, signal) {
  return request('api/v1/transaction', signal, {
    method: 'PATCH',
    body: { transaction_id: Number(id), ...payload },
  })
}

export function getTransfer(id, signal) {
  return request(`api/v1/transfer?id=${encodeURIComponent(id)}`, signal)
}

export function createTransfer(payload, signal) {
  return request('api/v1/transfer', signal, { method: 'POST', body: payload })
}

export function updateTransfer(id, payload, signal) {
  return request('api/v1/transfer', signal, {
    method: 'PATCH',
    body: { transfer_id: Number(id), ...payload },
  })
}

export function deleteTransfer(id, signal) {
  return request(`api/v1/transfer?id=${encodeURIComponent(id)}`, signal, {
    method: 'DELETE',
    allowEmpty: true,
  })
}

export function createTransactionFromText(text, signal) {
  return request('api/v1/transaction/text', signal, {
    method: 'POST',
    body: { text },
    allowEmpty: true,
    allowText: true,
  })
}

export function createTransactionFromPhoto(file, signal) {
  const form = new FormData()
  form.append('receipt', file)
  return request('api/v1/transaction/photo', signal, {
    method: 'POST',
    rawBody: form,
    allowEmpty: true,
    allowText: true,
  })
}

export function createTransactionFromVoice(blob, signal) {
  const form = new FormData()
  form.append('voice', blob, 'voice.webm')
  return request('api/v1/transaction/voice', signal, {
    method: 'POST',
    rawBody: form,
    allowEmpty: true,
    allowText: true,
  })
}

export function getTransactions({
  accountId,
  dateFrom,
  dateTo,
  incomeCategoryIds = null,
  expenseCategoryIds = null,
}, signal) {
  const params = new URLSearchParams({
    account_id: String(accountId),
    date_from: dateFrom,
    date_to: dateTo,
    include_descendants: 'false',
  })
  setOptionalIdFilter(params, 'selected_account_ids', [accountId])
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
  const params = new URLSearchParams({ date_from: dateFrom, date_to: dateTo })
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
  return request('api/v1/filter-presets', signal, { method: 'PATCH', body: { id: Number(id), name } })
}

export function deleteFilterPreset(id, signal) {
  return request(`api/v1/filter-presets?id=${encodeURIComponent(id)}`, signal, { method: 'DELETE', allowEmpty: true })
}

export function createAccount({ name, code, accountType, currencyCode, parentId = null }, signal) {
  return request('api/v1/accounts', signal, {
    method: 'POST',
    body: { name, code, account_type: accountType, currency_code: currencyCode, parent_id: parentId == null ? null : Number(parentId) },
  })
}

export function copyAccount(accountId, signal) {
  return request('api/v1/accounts/copy', signal, { method: 'POST', body: { account_id: Number(accountId) } })
}

export function editAccount({ accountId, name, accountType }, signal) {
  return request('api/v1/accounts', signal, { method: 'PATCH', body: { account_id: Number(accountId), name, account_type: accountType } })
}

export function consumeLastAccountMoveResult() {
  const result = lastAccountMoveResult
  lastAccountMoveResult = null
  return result
}

export async function moveAccount(accountId, parentId, signal) {
  lastAccountMoveResult = null
  try {
    const result = await request('api/v1/accounts/move', signal, { method: 'POST', body: { account_id: Number(accountId), parent_id: parentId == null ? null : Number(parentId) } })
    lastAccountMoveResult = { ok: true }
    return result
  } catch (error) {
    lastAccountMoveResult = { ok: false, message: error?.message || 'Не удалось переместить счёт' }
    throw error
  }
}

export function archiveAccount(accountId, signal) {
  return request('api/v1/accounts/archive', signal, { method: 'POST', body: { account_id: Number(accountId) } })
}

export function restoreAccount(accountId, signal) {
  return request('api/v1/accounts/restore', signal, { method: 'POST', body: { account_id: Number(accountId) } })
}

export function previewMoveAccountOperations(sourceAccountId, targetAccountId, signal) {
  return request('api/v1/accounts/move-operations/preview', signal, { method: 'POST', body: { source_account_id: Number(sourceAccountId), target_account_id: Number(targetAccountId) } })
}

export function moveAccountOperations(sourceAccountId, targetAccountId, signal) {
  return request('api/v1/accounts/move-operations', signal, { method: 'POST', body: { source_account_id: Number(sourceAccountId), target_account_id: Number(targetAccountId) } })
}

export function deleteAccount(accountId, signal) {
  return request(`api/v1/accounts?id=${encodeURIComponent(accountId)}`, signal, { method: 'DELETE', allowEmpty: true })
}
