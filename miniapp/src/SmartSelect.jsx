import { useMemo, useState } from 'react'
import { createPortal } from 'react-dom'

export function SmartSelect({
  label,
  value,
  options = [],
  onChange,
  placeholder = 'Выбрать',
  title = label,
  disabled = false,
  className = '',
}) {
  const [open, setOpen] = useState(false)
  const selected = useMemo(
    () => options.find((option) => String(option.value) === String(value)),
    [options, value],
  )

  const choose = (option) => {
    if (option.disabled) return
    onChange?.(String(option.value))
    setOpen(false)
  }

  return (
    <div className={`smartSelectField ${className}`.trim()}>
      {label && <span className="smartSelectLabel">{label}</span>}
      <button
        type="button"
        className="smartSelectTrigger"
        disabled={disabled}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen(true)}
      >
        <span className="smartSelectTriggerText">
          <strong className={!selected ? 'placeholder' : ''}>{selected?.label || placeholder}</strong>
          {selected?.secondary && <small>{selected.secondary}</small>}
        </span>
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m7 10 5 5 5-5" /></svg>
      </button>
      {open && createPortal(
        <div className="smartSelectBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && setOpen(false)}>
          <section className="smartSelectSheet" role="dialog" aria-modal="true" aria-label={title || 'Выбор'}>
            <header><strong>{title || 'Выбор'}</strong><button type="button" onClick={() => setOpen(false)} aria-label="Закрыть">×</button></header>
            <div className="smartSelectOptions">
              {options.map((option) => {
                const active = String(option.value) === String(value)
                const depth = Math.max(0, Number(option.depth || 0))
                return (
                  <button
                    type="button"
                    key={`${option.value}:${option.label}`}
                    className={`smartSelectOption ${active ? 'active' : ''} ${option.disabled ? 'disabled' : ''}`.trim()}
                    style={{ '--option-depth': depth }}
                    disabled={option.disabled}
                    onClick={() => choose(option)}
                    aria-pressed={active}
                  >
                    <span className="smartSelectTreeMark" aria-hidden="true">{depth > 0 ? '└' : option.hasChildren ? '▾' : '•'}</span>
                    <span className="smartSelectOptionText"><strong>{option.label}</strong>{option.secondary && <small>{option.secondary}</small>}</span>
                    {active && <span className="smartSelectCheck" aria-hidden="true">✓</span>}
                  </button>
                )
              })}
            </div>
          </section>
        </div>,
        document.body,
      )}
    </div>
  )
}
