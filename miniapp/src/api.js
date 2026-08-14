import { MoneyTrackApiError } from './api-errors.js'
import { clearUnlockSession, getUnlockToken } from './security-session.js'
import { getActiveSpaceId } from './space-context.js'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

let lastAccountMoveResult = null

const LOCK_ERROR_CODES = new Set(['UNLOCK_REQUIRED', 'UNLOCK_INVALID', 'UNLOCK_EXPIRED', 'MONEYTRACK_LOCKED'])

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

function captureRequestId(kind) {
  const prefix = String(kind || 'capture').replace(/[^A-Za-z0-9_-]/g, '') || 'capture'
  const uuid = globalThis.crypto?.randomUUID?.()
  if (uuid) return `${prefix}:${uuid}`
  const entropy = Math.random().toString(36).slice(2, 14)
  return `${prefix}:${Date.now().toString(36)}:${entropy}`
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
  const unlockToken = getUnlockToken()
  if (unlockToken) headers['X-MoneyTrack-Unlock-Token'] = unlockToken

  // SPC-001: this is untrusted routing input, never an authorization claim.
  // PostgreSQL/backend still asserts active membership on every financial request.
  const activeSpaceId = getActiveSpaceId()
  if (activeSpaceId != null) headers['X-MoneyTrack-Space-Id'] = String(activeSpaceId)

  const response = await fetch(`${API_BASE}/${path}`, {
    method,
    headers,
    body: rawBody !== undefined ? rawBody : body === undefined ? undefined : JSON.stringify(body),
    signal,
  })

  const { responseBody, payload } = await parseResponse(response, { allowText })

  if (!response.ok) {
    const code = errorCode(payload) || `HTTP_${response.status}`
    if (LOCK_ERROR_CODES.has(code)) {
      clearUnlockSession()
      window.dispatchEvent(new CustomEvent('moneytrack:locked', { detail: { code } }))
    }
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

// SPC-001 lifecycle routes are protected MiniApp routes but do not trust an
// existing active-space header for authorization; target Space is explicit in
// the request body and membership/owner checks happen server-side.
export async function getSpaces(signal) {
  const payload = await request('api/v1/spaces', signal, { allowEmpty: true })
  return payload ?? { spaces: [], current_space_id: null, default_capture_space_id: null }
}

export function createSpace(name, signal) {
  return request('api/v1/spaces', signal, { method: 'POST', body: { name } })
}

export function renameSpace(spaceId, name, signal) {
  return request('api/v1/spaces', signal, {
    method: 'PATCH', body: { space_id: Number(spaceId), name },
  })
}

export function archiveSpace(spaceId, signal) {
  return request('api/v1/spaces/archive', signal, {
    method: 'POST', body: { space_id: Number(spaceId) },
  })
}

export function setActiveSpace(spaceId, signal) {
  return request('api/v1/spaces/active', signal, {
    method: 'POST', body: { space_id: Number(spaceId) },
  })
}

export function setDefaultCaptureSpace(spaceId, signal) {
  return request('api/v1/spaces/default-capture', signal, {
    method: 'POST', body: { space_id: Number(spaceId) },
  })
}

export function createSpaceInvite(spaceId, signal) {
  return request('api/v1/spaces/invite', signal, {
    method: 'POST', body: { space_id: Number(spaceId) },
  })
}

export function revokeSpaceInvite(inviteId, signal) {
  return request('api/v1/spaces/invite/revoke', signal, {
    method: 'POST', body: { invite_id: Number(inviteId) },
  })
}

export function acceptSpaceInvite(inviteToken, signal) {
  return request('api/v1/spaces/invite/accept', signal, {
    method: 'POST', body: { invite_token: String(inviteToken || '') },
  })
}

export function getSpaceMembers(spaceId, signal) {
  return request(`api/v1/spaces/members?space_id=${encodeURIComponent(spaceId)}`, signal)
}

export function removeSpaceMember(spaceId, userId, signal) {
  return request('api/v1/spaces/members/remove', signal, {
    method: 'POST', body: { space_id: Number(spaceId), user_id: Number(userId) },
  })
}

export function getCaptureProjections(captureEventId, signal) {
  return request(`api/v1/capture/projections?capture_event_id=${encodeURIComponent(captureEventId)}`, signal)
}

export function projectCaptureToSpaces(captureEventId, targets, signal) {
  return request('api/v1/capture/projections', signal, {
    method: 'POST',
    body: { capture_event_id: Number(captureEventId), targets },
  })
}

export function getSecurityStatus(deviceId = '', signal) {
  const params = new URLSearchParams()
  if (deviceId) params.set('device_id', deviceId)
  const suffix = params.toString() ? `?${params.toString()}` : ''
  return request(`api/v1/security/status${suffix}`, signal)
}

export function setupSecurityPin(pin, signal) {
  return request('api/v1/security/pin/setup', signal, { method: 'POST', body: { pin } })
}

export function unlockWithPin(pin, signal) {
  return request('api/v1/security/pin/unlock', signal, { method: 'POST', body: { pin } })
}

export function changeSecurityPin(currentPin, newPin, newPinRepeat, signal) {
  return request('api/v1/security/pin/change', signal, {
    method: 'POST',
    body: { current_pin: currentPin, new_pin: newPin, new_pin_repeat: newPinRepeat },
  })
}

export function disableSecurity(currentPin, confirm, signal) {
  return request('api/v1/security/disable', signal, {
    method: 'POST',
    body: { current_pin: currentPin, confirm: confirm === true },
  })
}

export function unlockWithBiometric({ deviceId, biometricToken }, signal) {
  return request('api/v1/security/biometric/unlock', signal, {
    method: 'POST', body: { device_id: deviceId, biometric_token: biometricToken },
  })
}

export function enrollBiometric(deviceId, signal) {
  return request('api/v1/security/biometric/enroll', signal, { method: 'POST', body: { device_id: deviceId } })
}

export function revokeBiometric(deviceId, signal) {
  return request('api/v1/security/biometric/revoke', signal, { method: 'POST', body: { device_id: deviceId } })
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

export async function getReceiptByTransaction(transactionId, signal) {
  const payload = await request(`api/v1/receipt?transaction_id=${encodeURIComponent(transactionId)}`, signal, { allowEmpty: true })
  return payload?.receipt ?? null
}

export function updateReceiptAccounting(receiptId, accountId, currency, signal) {
  return request('api/v1/receipt/accounting', signal, {
    method: 'PATCH',
    body: {
      receipt_id: Number(receiptId),
      account_id: Number(accountId),
      currency: String(currency || '').toUpperCase(),
    },
  })
}

export function updateReceiptItemCategory(receiptItemId, categoryId, signal) {
  return request('api/v1/receipt-item/category', signal, {
    method: 'PATCH',
    body: { receipt_item_id: Number(receiptItemId), category_id: categoryId == null ? null : Number(categoryId) },
  })
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
    body: { text, request_id: captureRequestId('text') },
    allowEmpty: true,
    allowText: true,
  })
}

export function createTransactionFromPhoto(file, signal) {
  const form = new FormData()
  form.append('receipt', file)
  form.append('request_id', captureRequestId('photo'))
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
  form.append('request_id', captureRequestId('voice'))
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
