export function localDateKey(date) {
  const value = date instanceof Date ? date : new Date()
  const year = value.getFullYear()
  const month = String(value.getMonth() + 1).padStart(2, '0')
  const day = String(value.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function localDate(value) {
  if (value instanceof Date) return new Date(value.getFullYear(), value.getMonth(), value.getDate(), 12)
  const match = String(value || '').match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (!match) {
    const now = new Date()
    return new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)
  }
  return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12)
}

function addLocalDays(date, amount) {
  const next = localDate(date)
  next.setDate(next.getDate() + amount)
  return next
}

function formatShortDate(value, withYear = false) {
  return new Intl.DateTimeFormat('ru-RU', {
    day: '2-digit',
    month: '2-digit',
    ...(withYear ? { year: 'numeric' } : {}),
  }).format(localDate(value))
}

export function formatMonthLabel(date) {
  const parsed = typeof date === 'string' && /^\d{4}-\d{2}-\d{2}/.test(date)
    ? localDate(String(date).slice(0, 10))
    : date ? new Date(date) : new Date()
  const value = new Intl.DateTimeFormat('ru-RU', {
    month: 'long',
    year: 'numeric',
  }).format(parsed)

  const normalized = value
    .replace(/\sГ\.$/u, ' г.')
    .replace(/\sг\.$/u, ' г.')

  return normalized.replace(/^./u, (char) => char.toUpperCase())
}

export function resolvePeriod(periodType, anchorDate, customRange = {}) {
  const anchor = localDate(anchorDate)
  if (periodType === 'range') {
    const dateFrom = String(customRange.dateFrom || localDateKey(anchor)).slice(0, 10)
    const dateTo = String(customRange.dateTo || dateFrom).slice(0, 10)
    return {
      periodType,
      anchorDate: localDateKey(anchor),
      dateFrom,
      dateTo,
      displayLabel: `${formatShortDate(dateFrom, true)} — ${formatShortDate(dateTo, true)}`,
    }
  }

  if (periodType === 'week') {
    const mondayOffset = (anchor.getDay() + 6) % 7
    const monday = addLocalDays(anchor, -mondayOffset)
    const sunday = addLocalDays(monday, 6)
    const dateFrom = localDateKey(monday)
    const dateTo = localDateKey(sunday)
    return {
      periodType,
      anchorDate: localDateKey(anchor),
      dateFrom,
      dateTo,
      displayLabel: `${formatShortDate(dateFrom)} — ${formatShortDate(dateTo, true)}`,
    }
  }

  if (periodType === 'year') {
    const year = anchor.getFullYear()
    return {
      periodType,
      anchorDate: localDateKey(anchor),
      dateFrom: `${year}-01-01`,
      dateTo: `${year}-12-31`,
      displayLabel: String(year),
    }
  }

  const first = new Date(anchor.getFullYear(), anchor.getMonth(), 1, 12)
  const last = new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0, 12)
  return {
    periodType: 'month',
    anchorDate: localDateKey(anchor),
    dateFrom: localDateKey(first),
    dateTo: localDateKey(last),
    displayLabel: formatMonthLabel(localDateKey(first)),
  }
}

export function shiftPeriod(periodType, anchorDate, direction) {
  const delta = direction < 0 ? -1 : 1
  const anchor = localDate(anchorDate)
  if (periodType === 'week') return localDateKey(addLocalDays(anchor, delta * 7))
  if (periodType === 'year') return localDateKey(new Date(anchor.getFullYear() + delta, anchor.getMonth(), 1, 12))
  if (periodType === 'month') return localDateKey(new Date(anchor.getFullYear(), anchor.getMonth() + delta, 1, 12))
  return localDateKey(anchor)
}
