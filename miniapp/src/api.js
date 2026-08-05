const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

async function request(path, signal) {
  const response = await fetch(`${API_BASE}/${path}`, {
    method: 'GET',
    headers: {
      Accept: 'application/json',
      'X-Telegram-Init-Data': telegramInitData(),
    },
    signal,
  })

  if (!response.ok) {
    throw new Error(`API ${response.status}`)
  }

  const payload = await response.json()
  if (payload?.error) throw new Error(payload.error)
  return payload?.data ?? payload
}

export function getDashboard(signal) {
  return request('api/v1/dashboard', signal)
}

export function getAccounts(signal) {
  return request('api/v1/accounts', signal)
}
