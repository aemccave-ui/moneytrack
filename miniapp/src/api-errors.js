const messages = {
  DOMAIN_ERROR: 'Не удалось выполнить операцию. Проверьте условия и попробуйте ещё раз.',
  ACCOUNT_PARENT_HAS_OPERATIONS: 'Этот счёт содержит операции и не может быть родительским.',
  ACCOUNT_PARENT_IS_DEFAULT: 'Основной счёт нельзя использовать как группу. Сначала выберите другой основной счёт.',
  ACCOUNT_GROUP_NOT_POSTABLE: 'Операции нельзя записывать прямо в группу счетов. Выберите дочерний счёт.',
  ACCOUNT_HIERARCHY_CYCLE: 'Нельзя переместить счёт внутрь самого себя или своего дочернего счёта.',
  ACCOUNT_CURRENCY_INCOMPATIBLE: 'Валюты счетов несовместимы для этой операции.',
  ACCOUNT_CURRENCY_MISMATCH: 'Валюта операции должна совпадать с валютой счёта.',
  ACCOUNT_NOT_FOUND_OR_NOT_OWNED: 'Счёт не найден или недоступен.',
  ACCOUNT_BALANCE_NOT_ZERO: 'Счёт с ненулевым балансом нельзя архивировать.',
  ACCOUNT_DELETE_HAS_CHILDREN: 'Сначала перенесите или удалите дочерние счета.',
  ACCOUNT_DELETE_HAS_TRANSACTIONS: 'Счёт с историей операций нельзя удалить.',
  TRANSACTION_NOT_FOUND_OR_NOT_OWNED: 'Операция не найдена или недоступна.',
  TRANSACTION_TRANSFER_EDIT_UNSUPPORTED: 'Переводы редактируются как единая операция перевода и пока недоступны в этом редакторе.',
  CATEGORY_NOT_FOUND_OR_NOT_OWNED: 'Категория не найдена или недоступна.',
  INVALID_AMOUNT: 'Проверьте сумму операции.',
  INVALID_TRANSACTION_TYPE: 'Этот тип операции не поддерживается.',
  FX_RATE_NOT_FOUND: 'Не найден курс валюты на выбранную дату.',
  DATE_INVALID: 'Проверьте дату.',
  USER_REQUIRED: 'Не удалось определить пользователя Telegram.',
}

export function apiErrorMessage(code, fallback = '') {
  const normalized = String(code || '').trim()
  if (messages[normalized]) return messages[normalized]
  if (normalized.startsWith('FX_RATE_NOT_FOUND')) return messages.FX_RATE_NOT_FOUND
  if (normalized.startsWith('ACCOUNT_CURRENCY_MISMATCH')) return messages.ACCOUNT_CURRENCY_MISMATCH
  if (fallback && fallback !== normalized) return fallback
  return normalized ? `Не удалось выполнить операцию (${normalized}).` : 'Не удалось выполнить операцию.'
}

export class MoneyTrackApiError extends Error {
  constructor(code, fallback = '', status = null) {
    super(apiErrorMessage(code, fallback))
    this.name = 'MoneyTrackApiError'
    this.code = String(code || 'DOMAIN_ERROR')
    this.status = status
  }
}