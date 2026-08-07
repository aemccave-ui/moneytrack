const API_BASE = import.meta.env.VITE_API_BASE_URL || 'https://n8n.moneytrackapp.xyz/webhook'
const ACTION_REVEAL = 176
const SWIPE_THRESHOLD = 46

let operations = []
let enhanced = false

function telegramInitData() {
  return window.Telegram?.WebApp?.initData || ''
}

function localDateValue(date = new Date()) {
  const offset = date.getTimezoneOffset() * 60000
  return new Date(date.getTime() - offset).toISOString().slice(0, 10)
}

function formatDateTime(value) {
  if (!value) return '—'
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
  }).format(date)
}

function operationTypeLabel(type) {
  if (type === 'income') return 'Доход'
  if (type === 'expense') return 'Расход'
  if (type === 'openingbalance') return 'Начальный остаток'
  if (type === 'adjustment') return 'Корректировка'
  return type || 'Операция'
}

async function loadOperations() {
  const response = await fetch(`${API_BASE}/api/v1/dashboard`, {
    headers: {
      Accept: 'application/json',
      'X-Telegram-Init-Data': telegramInitData(),
    },
  })
  if (!response.ok) throw new Error(`API ${response.status}`)
  const payload = await response.json()
  const dashboard = payload?.data ?? payload
  operations = dashboard?.latest_operations || []
}

function showMessage(message) {
  if (window.Telegram?.WebApp?.showAlert) {
    window.Telegram.WebApp.showAlert(message)
    return
  }
  window.alert(message)
}

function confirmDelete(operation) {
  const description = operation.description || operation.account_name || 'Операция'
  const amount = `${Math.abs(Number(operation.amount_original || 0))} ${operation.currency_original || ''}`.trim()
  const message = `Удалить операцию «${description}»${amount ? ` на ${amount}` : ''}?`
  if (window.Telegram?.WebApp?.showConfirm) {
    return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  }
  return Promise.resolve(window.confirm(message))
}

async function deleteOperation(operation) {
  const response = await fetch(`${API_BASE}/api/v1/transaction?id=${encodeURIComponent(operation.id)}`, {
    method: 'DELETE',
    headers: {
      Accept: 'application/json',
      'X-Telegram-Init-Data': telegramInitData(),
    },
  })
  const body = await response.text()
  if (!response.ok) {
    throw new Error(`Удаление недоступно: API ${response.status}${body ? ` — ${body.slice(0, 100)}` : ''}`)
  }
}

function detailRow(label, value) {
  const row = document.createElement('div')
  row.className = 'transactionDetailRow'
  const key = document.createElement('span')
  key.textContent = label
  const text = document.createElement('strong')
  text.textContent = value ?? '—'
  row.append(key, text)
  return row
}

function toggleDetails(row, operation) {
  const existing = row.querySelector(':scope > .transactionDetails')
  if (existing) {
    existing.remove()
    row.classList.remove('detailsOpen')
    return
  }

  document.querySelectorAll('.transaction.detailsOpen').forEach((other) => {
    if (other !== row) {
      other.querySelector(':scope > .transactionDetails')?.remove()
      other.classList.remove('detailsOpen')
    }
  })

  row.classList.remove('actionsOpen')
  const details = document.createElement('div')
  details.className = 'transactionDetails'
  details.append(
    detailRow('Тип', operationTypeLabel(operation.transaction_type)),
    detailRow('Сумма', String(operation.amount_original ?? '—')),
    detailRow('Валюта', operation.currency_original || '—'),
    detailRow('Счёт', operation.account_name || '—'),
    detailRow('Категория', operation.category_name || operation.category_id || '—'),
    detailRow('Дата', formatDateTime(operation.transaction_date)),
    detailRow('Описание', operation.description || '—'),
  )
  row.append(details)
  row.classList.add('detailsOpen')
}

function field(label, input) {
  const wrapper = document.createElement('label')
  wrapper.className = 'transactionEditorField'
  const title = document.createElement('span')
  title.textContent = label
  wrapper.append(title, input)
  return wrapper
}

function input(type, value = '') {
  const element = document.createElement('input')
  element.type = type
  element.value = value == null ? '' : String(value)
  return element
}

function openEditor(operation, mode) {
  document.querySelector('.transactionEditorBackdrop')?.remove()
  const repeat = mode === 'repeat'
  const backdrop = document.createElement('div')
  backdrop.className = 'transactionEditorBackdrop'

  const sheet = document.createElement('section')
  sheet.className = 'transactionEditorSheet'
  sheet.setAttribute('role', 'dialog')
  sheet.setAttribute('aria-modal', 'true')
  sheet.setAttribute('aria-label', repeat ? 'Повторить операцию' : 'Изменить операцию')

  const header = document.createElement('div')
  header.className = 'transactionEditorHeader'
  const heading = document.createElement('div')
  const eyebrow = document.createElement('span')
  eyebrow.textContent = repeat ? 'Новая операция' : 'Операция'
  const title = document.createElement('strong')
  title.textContent = repeat ? 'Повторить' : 'Изменить'
  heading.append(eyebrow, title)
  const close = document.createElement('button')
  close.type = 'button'
  close.className = 'transactionEditorClose'
  close.setAttribute('aria-label', 'Закрыть')
  close.textContent = '×'
  header.append(heading, close)

  const form = document.createElement('div')
  form.className = 'transactionEditorForm'

  const typeSelect = document.createElement('select')
  ;[['expense', 'Расход'], ['income', 'Доход'], ['adjustment', 'Корректировка']].forEach(([value, label]) => {
    const option = document.createElement('option')
    option.value = value
    option.textContent = label
    typeSelect.append(option)
  })
  typeSelect.value = operation.transaction_type || 'expense'

  form.append(
    field('Тип', typeSelect),
    field('Сумма', input('number', Math.abs(Number(operation.amount_original || 0)))),
    field('Валюта', input('text', operation.currency_original || 'EUR')),
    field('Счёт', input('text', operation.account_name || '')),
    field('Категория', input('text', operation.category_name || operation.category_id || '')),
    field('Дата', input('date', repeat ? localDateValue() : String(operation.transaction_date || '').slice(0, 10))),
    field('Описание', input('text', operation.description || '')),
  )

  const note = document.createElement('p')
  note.className = 'transactionEditorNote'
  note.textContent = repeat
    ? 'Интерфейс готов. Сохранение повторённой операции будет подключено следующим этапом.'
    : 'Интерфейс готов. Сохранение изменений будет подключено следующим этапом.'

  const save = document.createElement('button')
  save.type = 'button'
  save.className = 'transactionEditorSave'
  save.disabled = true
  save.textContent = 'Сохранить · скоро'

  const dismiss = () => backdrop.remove()
  close.addEventListener('click', dismiss)
  backdrop.addEventListener('click', (event) => {
    if (event.target === backdrop) dismiss()
  })

  sheet.append(header, form, note, save)
  backdrop.append(sheet)
  document.body.append(backdrop)
  requestAnimationFrame(() => backdrop.classList.add('visible'))
}

function createActions(row, operation) {
  const actions = document.createElement('div')
  actions.className = 'transactionSwipeActions'

  const repeat = document.createElement('button')
  repeat.type = 'button'
  repeat.className = 'transactionSwipeAction repeat'
  repeat.innerHTML = '<span aria-hidden="true">↻</span><small>Повторить</small>'

  const edit = document.createElement('button')
  edit.type = 'button'
  edit.className = 'transactionSwipeAction edit'
  edit.innerHTML = '<span aria-hidden="true">✎</span><small>Изменить</small>'

  const remove = document.createElement('button')
  remove.type = 'button'
  remove.className = 'transactionSwipeAction delete'
  remove.innerHTML = '<span aria-hidden="true">×</span><small>Удалить</small>'

  repeat.addEventListener('click', (event) => {
    event.stopPropagation()
    row.classList.remove('actionsOpen')
    openEditor(operation, 'repeat')
  })
  edit.addEventListener('click', (event) => {
    event.stopPropagation()
    row.classList.remove('actionsOpen')
    openEditor(operation, 'edit')
  })
  remove.addEventListener('click', async (event) => {
    event.stopPropagation()
    if (!(await confirmDelete(operation))) return
    remove.disabled = true
    try {
      await deleteOperation(operation)
      row.remove()
      window.location.reload()
    } catch (error) {
      remove.disabled = false
      showMessage(error.message || 'Не удалось удалить операцию')
    }
  })

  actions.append(repeat, edit, remove)
  row.append(actions)
}

function enhanceRow(row, operation, index) {
  if (row.dataset.recentOperationEnhanced === 'true') return
  row.dataset.recentOperationEnhanced = 'true'
  row.dataset.transactionId = operation.id ?? ''
  row.dataset.operationIndex = String(index + 1)
  row.setAttribute('role', 'button')
  row.setAttribute('tabindex', '0')
  row.setAttribute('aria-label', `${operation.description || operation.account_name || 'Операция'}. Нажмите для деталей, проведите вправо для действий.`)

  createActions(row, operation)

  let startX = 0
  let startY = 0
  let dragging = false
  let swiped = false

  row.addEventListener('pointerdown', (event) => {
    if (event.target.closest('.transactionSwipeActions, .transactionDetails')) return
    startX = event.clientX
    startY = event.clientY
    dragging = true
    swiped = false
    row.setPointerCapture?.(event.pointerId)
  })

  row.addEventListener('pointermove', (event) => {
    if (!dragging) return
    const dx = event.clientX - startX
    const dy = event.clientY - startY
    if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 8) {
      dragging = false
      return
    }
    if (dx > 8) {
      swiped = true
      row.style.setProperty('--transaction-swipe-x', `${Math.min(ACTION_REVEAL, dx)}px`)
    }
  })

  const finishSwipe = (event) => {
    if (!dragging && !swiped) return
    const dx = event.clientX - startX
    row.style.removeProperty('--transaction-swipe-x')
    dragging = false
    if (dx >= SWIPE_THRESHOLD) {
      document.querySelectorAll('.transaction.actionsOpen').forEach((other) => other !== row && other.classList.remove('actionsOpen'))
      row.querySelector(':scope > .transactionDetails')?.remove()
      row.classList.remove('detailsOpen')
      row.classList.add('actionsOpen')
      swiped = true
    } else if (swiped) {
      row.classList.remove('actionsOpen')
    }
    setTimeout(() => { swiped = false }, 0)
  }

  row.addEventListener('pointerup', finishSwipe)
  row.addEventListener('pointercancel', () => {
    dragging = false
    row.style.removeProperty('--transaction-swipe-x')
  })

  row.addEventListener('click', (event) => {
    if (swiped || event.target.closest('.transactionSwipeActions, .transactionDetails')) return
    if (row.classList.contains('actionsOpen')) {
      row.classList.remove('actionsOpen')
      return
    }
    toggleDetails(row, operation)
  })

  row.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      toggleDetails(row, operation)
    }
  })
}

function enhanceRows() {
  const rows = [...document.querySelectorAll('.transactionPanel .transaction')]
  if (!rows.length || !operations.length) return false
  rows.forEach((row, index) => {
    if (operations[index]) enhanceRow(row, operations[index], index)
  })
  return true
}

async function boot() {
  if (enhanced) return
  enhanced = true
  try {
    await loadOperations()
  } catch {
    enhanced = false
    return
  }

  if (enhanceRows()) return
  const observer = new MutationObserver(() => {
    if (enhanceRows()) observer.disconnect()
  })
  observer.observe(document.documentElement, { childList: true, subtree: true })
}

const observer = new MutationObserver(() => {
  if (document.querySelector('.transactionPanel')) {
    observer.disconnect()
    boot()
  }
})
observer.observe(document.documentElement, { childList: true, subtree: true })
if (document.querySelector('.transactionPanel')) boot()
