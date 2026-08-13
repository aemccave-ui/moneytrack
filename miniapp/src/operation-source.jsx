import { OPERATION_SOURCE_LABEL, operationSourceKind } from './operation-source.js'

function SourceGlyph({ kind }) {
  if (kind === 'text') return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 6h14M5 10h10M5 14h8M5 18h5" /></svg>
  if (kind === 'voice') return <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="4" width="6" height="11" rx="3" /><path d="M6.5 11.5a5.5 5.5 0 0 0 11 0M12 17v3M9 20h6" /></svg>
  if (kind === 'photo_receipt') return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4h14v16l-2-1.5L15 20l-3-1.5L9 20l-2-1.5L5 20V4Z" /><path d="M8 8h8M8 11h8M8 14h5" /></svg>
  return <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4v16M8.5 7.5 12 4l3.5 3.5" /></svg>
}

export function OperationSourceIcon({ operation, kind: explicitKind, className = '' }) {
  const kind = explicitKind || operationSourceKind(operation)
  if (!kind) return null
  const label = OPERATION_SOURCE_LABEL[kind]
  return <span className={`operationSourceIcon ${className}`.trim()} title={`Источник: ${label}`} aria-label={`Источник: ${label}`}><SourceGlyph kind={kind} /></span>
}
