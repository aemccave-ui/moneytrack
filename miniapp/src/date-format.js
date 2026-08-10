export function formatMonthLabel(date) {
  const value = new Intl.DateTimeFormat('ru-RU', {
    month: 'long',
    year: 'numeric',
  }).format(date ? new Date(date) : new Date())

  const normalized = value
    .replace(/\sГ\.$/u, ' г.')
    .replace(/\sг\.$/u, ' г.')

  return normalized.replace(/^./u, (char) => char.toUpperCase())
}
