import { MoneyTrackApiError } from './api-errors.js'
import { clearUnlockSession, getUnlockToken } from './security-session.js'
import { getActiveSpaceId } from './space-context.js'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'
const LOCK_ERROR_CODES = new Set(['UNLOCK_REQUIRED', 'UNLOCK_INVALID', 'UNLOCK_EXPIRED', 'MONEYTRACK_LOCKED'])
const SPACE_ERROR_CODES = new Set(['SPACE_CONTEXT_NOT_FOUND', 'SPACE_NOT_FOUND_OR_NOT_MEMBER'])

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

async function categoryRequest(method, { query = '', body, signal } = {}) {
  const activeSpaceId = getActiveSpaceId()
  if (activeSpaceId == null) {
    throw new MoneyTrackApiError('SPACE_CONTEXT_NOT_FOUND', 'Не выбрано финансовое пространство.', 400)
  }

  const headers = {
    Accept: 'application/json',
    'X-Telegram-Init-Data': telegramInitData(),
    'X-MoneyTrack-Space-Id': String(activeSpaceId),
  }
  const unlockToken = getUnlockToken()
  if (unlockToken) headers['X-MoneyTrack-Unlock-Token'] = unlockToken
  if (body !== undefined) headers['Content-Type'] = 'application/json'

  const response = await fetch(`${API_BASE}/api/v1/categories${query}`, {
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
      throw new MoneyTrackApiError('API_RESPONSE_INVALID', 'Сервис вернул некорректный ответ.', response.status)
    }
  }

  if (!response.ok) {
    const code = errorCode(payload) || `HTTP_${response.status}`
    if (LOCK_ERROR_CODES.has(code)) {
      clearUnlockSession()
      window.dispatchEvent(new CustomEvent('moneytrack:locked', { detail: { code } }))
    }
    if (SPACE_ERROR_CODES.has(code)) {
      window.dispatchEvent(new CustomEvent('moneytrack:space-invalid', {
        detail: new MoneyTrackApiError(code, errorMessage(payload), response.status),
      }))
    }
    throw new MoneyTrackApiError(code, errorMessage(payload), response.status)
  }

  const code = errorCode(payload)
  if (code) throw new MoneyTrackApiError(code, errorMessage(payload), response.status)
  return payload?.data ?? payload ?? {}
}

export async function getCategoryDirectory(signal) {
  const payload = await categoryRequest('GET', { signal })
  return payload?.categories || []
}

export async function createCategory({ name, flowType, parentId = null }, signal) {
  const payload = await categoryRequest('POST', {
    signal,
    body: {
      name,
      flow_type: flowType,
      parent_id: parentId == null ? null : Number(parentId),
    },
  })
  return payload?.category || payload
}

export async function editCategory({ categoryId, name, flowType, parentId = null, sortOrder }, signal) {
  const payload = await categoryRequest('PATCH', {
    signal,
    body: {
      category_id: Number(categoryId),
      name,
      flow_type: flowType,
      parent_id: parentId == null ? null : Number(parentId),
      sort_order: Number(sortOrder),
    },
  })
  return payload?.category || payload
}

export function reorderCategory(categoryId, direction, signal) {
  return categoryRequest('PATCH', {
    signal,
    body: {
      category_id: Number(categoryId),
      action: 'reorder',
      direction,
    },
  })
}

export function deleteCategory(categoryId, signal) {
  return categoryRequest('DELETE', {
    signal,
    query: `?id=${encodeURIComponent(categoryId)}`,
  })
}
