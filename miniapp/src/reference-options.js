export const ACCOUNT_TYPE_OPTIONS = [
  { value: 'cash', label: 'Наличные' },
  { value: 'bank', label: 'Банковский счёт' },
  { value: 'card', label: 'Карта' },
  { value: 'savings', label: 'Сбережения' },
  { value: 'investment', label: 'Инвестиции' },
  { value: 'other', label: 'Другой' },
]

export function accountTypeOptions(current = null) {
  const value = String(current || '').trim()
  if (!value || ACCOUNT_TYPE_OPTIONS.some((item) => item.value === value)) return ACCOUNT_TYPE_OPTIONS
  return [...ACCOUNT_TYPE_OPTIONS, { value, label: value }]
}

export function currencyCode(item) {
  return String(item?.code || item || '').trim().toUpperCase()
}

export function currencyName(code) {
  try {
    return new Intl.DisplayNames(['ru'], { type: 'currency' }).of(code) || code
  } catch {
    return code
  }
}

export function orderedCurrencyCodes(referenceCurrencies = [], usedCurrencies = [], currentCurrency = null) {
  const reference = referenceCurrencies
    .map((item) => ({
      code: currencyCode(item),
      usageCount: Number(item?.usage_count ?? 0),
    }))
    .filter((item) => item.code)

  const all = new Set(reference.map((item) => item.code))
  const used = new Set(
    reference.filter((item) => item.usageCount > 0).map((item) => item.code),
  )

  usedCurrencies.map(currencyCode).filter(Boolean).forEach((code) => {
    all.add(code)
    used.add(code)
  })

  const current = currencyCode(currentCurrency)
  if (current) all.add(current)

  const sort = (left, right) => left.localeCompare(right, 'en')
  return [
    ...[...used].sort(sort),
    ...[...all].filter((code) => !used.has(code)).sort(sort),
  ]
}

export function currencyOptions(referenceCurrencies = [], usedCurrencies = [], currentCurrency = null) {
  return orderedCurrencyCodes(referenceCurrencies, usedCurrencies, currentCurrency)
    .map((code) => ({ value: code, label: code, secondary: currencyName(code) }))
}
