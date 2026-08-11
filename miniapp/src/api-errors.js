const messages = {
  DOMAIN_ERROR: 'Не удалось выполнить операцию. Проверьте условия и попробуйте ещё раз.',
  HTTP_404: 'Эта функция сейчас не подключена на сервере.',
  HTTP_401: 'Сессия Telegram устарела. Закройте и снова откройте MoneyTrack.',
  HTTP_403: 'Недостаточно прав для этой операции.',
  HTTP_500: 'Сервис временно не смог выполнить операцию. Попробуйте ещё раз.',
  API_RESPONSE_INVALID: 'Сервис вернул некорректный ответ.',
  API_RESPONSE_EMPTY: 'Сервис не подтвердил выполнение операции.',
  INIT_DATA_MISSING: 'Не удалось подтвердить сессию Telegram. Закройте и снова откройте MoneyTrack.',
  INVALID_INIT_DATA: 'Не удалось подтвердить сессию Telegram. Закройте и снова откройте MoneyTrack.',
  INVALID_INIT_DATA_HASH: 'Не удалось подтвердить сессию Telegram. Закройте и снова откройте MoneyTrack.',
  AUTH_DATE_MISSING: 'Сессия Telegram недействительна. Откройте MoneyTrack заново.',
  AUTH_DATE_INVALID: 'Сессия Telegram недействительна. Откройте MoneyTrack заново.',
  AUTH_DATE_EXPIRED: 'Сессия Telegram устарела. Закройте и снова откройте MoneyTrack.',
  AUTH_DATE_IN_FUTURE: 'Не удалось подтвердить время сессии Telegram. Откройте MoneyTrack заново.',
  USER_NOT_FOUND: 'Пользователь MoneyTrack не найден.',
  ACCOUNT_PARENT_HAS_OPERATIONS: 'Этот счёт содержит операции и не может быть родительским.',
  ACCOUNT_PARENT_IS_DEFAULT: 'Основной счёт нельзя использовать как группу. Сначала выберите другой основной счёт.',
  ACCOUNT_GROUP_NOT_POSTABLE: 'Операции нельзя записывать прямо в группу счетов. Выберите дочерний счёт.',
  ACCOUNT_HIERARCHY_CYCLE: 'Нельзя переместить счёт внутрь самого себя или своего дочернего счёта.',
  ACCOUNT_CURRENCY_INCOMPATIBLE: 'Валюты счетов несовместимы для этой операции.',
  ACCOUNT_CURRENCY_MISMATCH: 'Валюта операции должна совпадать с валютой счёта.',
  ACCOUNT_NOT_FOUND_OR_NOT_OWNED: 'Счёт не найден или недоступен.',
  FROM_ACCOUNT_NOT_FOUND_OR_NOT_OWNED: 'Счёт списания не найден или недоступен.',
  TO_ACCOUNT_NOT_FOUND_OR_NOT_OWNED: 'Счёт зачисления не найден или недоступен.',
  ACCOUNT_BALANCE_NOT_ZERO: 'Счёт с ненулевым балансом нельзя архивировать.',
  ACCOUNT_DELETE_HAS_CHILDREN: 'Сначала перенесите или удалите дочерние счета.',
  ACCOUNT_DELETE_HAS_TRANSACTIONS: 'Счёт с историей операций нельзя удалить.',
  TRANSACTION_NOT_FOUND_OR_NOT_OWNED: 'Операция не найдена или недоступна.',
  TRANSACTION_TRANSFER_EDIT_UNSUPPORTED: 'Перевод связан с двумя счетами и редактируется отдельно.',
  TRANSFER_NOT_FOUND_OR_NOT_OWNED: 'Перевод не найден или недоступен.',
  TRANSFER_ID_INVALID: 'Не удалось определить перевод.',
  FROM_ACCOUNT_ID_INVALID: 'Выберите счёт списания.',
  TO_ACCOUNT_ID_INVALID: 'Выберите счёт зачисления.',
  SAME_ACCOUNT_TRANSFER_FORBIDDEN: 'Счёт списания и счёт зачисления должны отличаться.',
  INVALID_TRANSFER_AMOUNT: 'Проверьте сумму перевода.',
  INVALID_TRANSFER_TYPE: 'Этот тип перевода не поддерживается.',
  TRANSFER_CURRENCY_MISMATCH: 'Обычный перевод возможен только между счетами в одной валюте.',
  EXCHANGE_REQUIRES_DIFFERENT_CURRENCIES: 'Для обмена выберите счета в разных валютах.',
  FX_CONVERSION_UNAVAILABLE: 'Не удалось рассчитать сумму зачисления по курсу на выбранную дату.',
  CATEGORY_NOT_FOUND_OR_NOT_OWNED: 'Категория не найдена или недоступна.',
  OPENING_BALANCE_ALREADY_EXISTS: 'У этого счёта уже есть начальный остаток.',
  IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD: 'Повторный запрос не совпадает с исходной операцией.',
  INVALID_AMOUNT: 'Проверьте сумму операции.',
  INVALID_TRANSACTION_TYPE: 'Этот тип операции не поддерживается.',
  FX_RATE_NOT_FOUND: 'Не найден курс валюты на выбранную дату.',
  DATE_INVALID: 'Проверьте дату.',
  DATE_REQUIRED: 'Проверьте дату.',
  USER_REQUIRED: 'Не удалось определить пользователя Telegram.',
  TEXT_REQUIRED: 'Введите описание операции.',
  PHOTO_BINARY_MISSING: 'Не удалось получить выбранное фото.',
  VOICE_BINARY_MISSING: 'Не удалось получить аудиозапись.',
  VOICE_TEXT_EMPTY: 'Не удалось распознать речь. Попробуйте записать ещё раз.',
  VOICE_PROCESSOR_ERROR: 'Не удалось обработать аудиозапись. Попробуйте ещё раз.',
}

export function apiErrorMessage(code, fallback = '') {
  const normalized = String(code || '').trim()
  if (messages[normalized]) return messages[normalized]
  if (normalized.startsWith('FX_RATE_NOT_FOUND')) return messages.FX_RATE_NOT_FOUND
  if (normalized.startsWith('FX_CONVERSION_UNAVAILABLE')) return messages.FX_CONVERSION_UNAVAILABLE
  if (normalized.startsWith('ACCOUNT_CURRENCY_MISMATCH')) return messages.ACCOUNT_CURRENCY_MISMATCH
  if (normalized.startsWith('TRANSFER_CURRENCY_MISMATCH')) return messages.TRANSFER_CURRENCY_MISMATCH
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
