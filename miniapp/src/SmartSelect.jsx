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

export function hierarchyOptions(items = [], {
  id = (item) => item?.id,
  parent = (item) => item?.parent_id ?? null,
  children = (item) => item?.children || [],
  label = (item) => item?.name || String(id(item) ?? ''),
  secondary = () => '',
  disabled = () => false,
} = {}) {
  const byId = new Map()

  const ingest = (item, inheritedParent = null) => {
    if (!item) return
    const itemId = id(item)
    if (itemId == null) return
    const ownParent = parent(item)
    const normalized = ownParent == null && inheritedParent != null
      ? { ...item, parent_id: inheritedParent }
      : item
    byId.set(String(itemId), normalized)
    ;(children(item) || []).forEach((child) => ingest(child, itemId))
  }
  items.forEach((item) => ingest(item))

  const childMap = new Map()
  const roots = []
  byId.forEach((item, key) => {
    const parentId = parent(item)
    const parentKey = parentId == null ? null : String(parentId)
    if (parentKey && byId.has(parentKey) && parentKey !== key) {
      if (!childMap.has(parentKey)) childMap.set(parentKey, [])
      childMap.get(parentKey).push(item)
    } else {
      roots.push(item)
    }
  })

  const sorter = (a, b) => String(label(a)).localeCompare(String(label(b)), 'ru')
  roots.sort(sorter)
  childMap.forEach((list) => list.sort(sorter))

  const result = []
  const visited = new Set()
  const visit = (item, depth) => {
    const key = String(id(item))
    if (visited.has(key)) return
    visited.add(key)
    const childItems = childMap.get(key) || []
    result.push({
      value: key,
      label: label(item),
      secondary: secondary(item),
      depth,
      hasChildren: childItems.length > 0,
      disabled: disabled(item, childItems),
      source: item,
    })
    childItems.forEach((child) => visit(child, depth + 1))
  }
  roots.forEach((item) => visit(item, 0))
  byId.forEach((item) => {
    if (!visited.has(String(id(item)))) visit(item, 0)
  })
  return result
}
