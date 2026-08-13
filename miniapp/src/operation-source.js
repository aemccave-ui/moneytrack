const SOURCE_KIND_BY_TYPE = Object.freeze({
  miniapp: 'manual',
  manual: 'manual',
  text: 'text',
  voice: 'voice',
  photo_receipt: 'photo_receipt',
})

export const OPERATION_SOURCE_LABEL = Object.freeze({
  manual: 'Вручную',
  text: 'Текст',
  voice: 'Голос',
  photo_receipt: 'Фото чека',
})

export function operationSourceKind(operation = {}) {
  const canonical = String(operation.source_kind || '').trim().toLowerCase()
  if (OPERATION_SOURCE_LABEL[canonical]) return canonical
  const sourceType = String(operation.source_type || '').trim().toLowerCase()
  return SOURCE_KIND_BY_TYPE[sourceType] || null
}
