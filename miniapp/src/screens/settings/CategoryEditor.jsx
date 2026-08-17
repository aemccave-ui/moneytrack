import { useMemo, useState } from 'react'

export default function CategoryEditor({ category = null, categories, onCancel, onSave, busy }) {
  const creating = !category
  const [name, setName] = useState(category?.name || '')
  const [flowType, setFlowType] = useState(category?.flow_type || 'expense')
  const [parentId, setParentId] = useState(category?.parent_id == null ? '' : String(category.parent_id))

  const blockedParentIds = useMemo(() => {
    if (!category) return new Set()
    const children = new Map()
    categories.forEach((item) => {
      const key = item.parent_id == null ? '' : String(item.parent_id)
      if (!children.has(key)) children.set(key, [])
      children.get(key).push(String(item.id))
    })
    const blocked = new Set([String(category.id)])
    const queue = [String(category.id)]
    while (queue.length) {
      const id = queue.shift()
      ;(children.get(id) || []).forEach((childId) => {
        if (!blocked.has(childId)) {
          blocked.add(childId)
          queue.push(childId)
        }
      })
    }
    return blocked
  }, [categories, category])

  const parentOptions = categories.filter((item) => !blockedParentIds.has(String(item.id)))
  const valid = Boolean(name.trim() && (flowType === 'income' || flowType === 'expense'))

  const submit = (event) => {
    event.preventDefault()
    if (!valid || busy) return
    onSave({
      categoryId: category?.id ?? null,
      name: name.trim(),
      flowType,
      parentId: parentId ? Number(parentId) : null,
      sortOrder: Number(category?.sort_order ?? 0),
    })
  }

  return (
    <form className="categoryEditor" onSubmit={submit}>
      <header className="categoryEditorHeader">
        <div><span>{creating ? 'Новая категория' : 'Категория'}</span><strong>{creating ? 'Добавить категорию' : 'Изменить категорию'}</strong></div>
        <button type="button" onClick={onCancel} aria-label="Закрыть редактор">×</button>
      </header>

      <label>
        <span>Название</span>
        <input value={name} onChange={(event) => setName(event.target.value)} maxLength={120} autoFocus disabled={busy} />
      </label>

      <label>
        <span>Тип</span>
        <select value={flowType} onChange={(event) => setFlowType(event.target.value)} disabled={busy}>
          <option value="expense">Расход</option>
          <option value="income">Приход</option>
        </select>
      </label>

      <label>
        <span>Родительская категория</span>
        <select value={parentId} onChange={(event) => setParentId(event.target.value)} disabled={busy}>
          <option value="">Без родителя</option>
          {parentOptions.map((item) => <option value={item.id} key={item.id}>{item.name || item.code}</option>)}
        </select>
      </label>

      <div className="categoryEditorActions">
        <button type="button" className="secondary" onClick={onCancel} disabled={busy}>Отмена</button>
        <button type="submit" disabled={!valid || busy}>{busy ? 'Сохраняю…' : 'Сохранить'}</button>
      </div>
    </form>
  )
}
