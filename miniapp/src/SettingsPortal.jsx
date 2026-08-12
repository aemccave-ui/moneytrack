import { useEffect, useMemo, useState } from 'react'
import { getTransactionReference, updateCategory } from './api.js'
import './settings-categories.css'

function flattenCategories(items = []) {
  const byId = new Map(items.map((item) => [String(item.id), { item, children: [] }]))
  const roots = []
  byId.forEach((node) => {
    const parent = node.item.parent_id == null ? null : byId.get(String(node.item.parent_id))
    if (parent && parent !== node) parent.children.push(node)
    else roots.push(node)
  })
  const sort = (a, b) => {
    const order = Number(a.item.sort_order || 0) - Number(b.item.sort_order || 0)
    return order || String(a.item.name || a.item.code || '').localeCompare(String(b.item.name || b.item.code || ''), 'ru')
  }
  const result = []
  const visit = (node, depth) => {
    result.push({ ...node.item, depth })
    node.children.sort(sort).forEach((child) => visit(child, depth + 1))
  }
  roots.sort(sort).forEach((node) => visit(node, 0))
  return result
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function CategorySettingsRow({ category, onSaved }) {
  const [name, setName] = useState(category.name || category.code || '')
  const [flowType, setFlowType] = useState(category.flow_type === 'income' ? 'income' : 'expense')
  const [saving, setSaving] = useState(false)
  const editable = category.editable !== false
  const changed = name.trim() !== String(category.name || category.code || '').trim()
    || flowType !== (category.flow_type === 'income' ? 'income' : 'expense')

  const save = async () => {
    if (!editable || !changed || !name.trim() || saving) return
    setSaving(true)
    try {
      const result = await updateCategory({
        categoryId: category.id,
        name: name.trim(),
        flowType,
      })
      onSaved(result?.category || result || { ...category, name: name.trim(), flow_type: flowType })
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить категорию')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="settingsCategoryRow" style={{ '--settings-category-depth': category.depth || 0 }}>
      <div className="settingsCategoryMain">
        <input aria-label={`Название категории ${category.name || category.code}`} value={name} onChange={(event) => setName(event.target.value)} disabled={!editable} />
        <small>{category.code}{!editable ? ' · системная' : ''}</small>
      </div>
      <select aria-label={`Тип категории ${category.name || category.code}`} value={flowType} onChange={(event) => setFlowType(event.target.value)} disabled={!editable}>
        <option value="expense">Расход</option>
        <option value="income">Приход</option>
      </select>
      <button type="button" onClick={save} disabled={!editable || !changed || saving || !name.trim()}>{saving ? '…' : '✓'}</button>
    </div>
  )
}

export default function SettingsPortal() {
  const [open, setOpen] = useState(false)
  const [categories, setCategories] = useState([])
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    const click = (event) => {
      const button = event.target.closest('button, a')
      if (!button) return
      const label = button.textContent?.trim()
      if (!label?.includes('Настройки')) return
      event.preventDefault()
      event.stopPropagation()
      setOpen(true)
    }
    document.addEventListener('click', click, true)
    return () => document.removeEventListener('click', click, true)
  }, [])

  useEffect(() => {
    if (!open) return undefined
    const controller = new AbortController()
    setLoading(true)
    getTransactionReference(controller.signal)
      .then((result) => setCategories(result?.categories || []))
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить категории')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [open])

  const rows = useMemo(() => flattenCategories(categories), [categories])
  if (!open) return null

  const updateLocal = (updated) => setCategories((current) => current.map((item) => (
    String(item.id) === String(updated.id) ? { ...item, ...updated } : item
  )))

  return (
    <div className="settingsScreenBackdrop" role="presentation">
      <section className="settingsScreen" role="dialog" aria-modal="true" aria-label="Настройки">
        <header className="settingsScreenHeader">
          <div><span>Настройки</span><strong>Категории</strong></div>
          <button type="button" onClick={() => setOpen(false)} aria-label="Закрыть">×</button>
        </header>
        <p className="settingsCategoryHint">Для каждой категории задаётся один финансовый тип. Он используется в фильтрах и в выборе категории операции.</p>
        <div className="settingsCategoryHead"><span>Категория</span><span>Приход / расход</span><span /></div>
        <div className="settingsCategoryList">
          {loading && <div className="settingsCategoryEmpty">Загрузка…</div>}
          {!loading && !rows.length && <div className="settingsCategoryEmpty">Категорий пока нет</div>}
          {rows.map((category) => <CategorySettingsRow key={category.id} category={category} onSaved={updateLocal} />)}
        </div>
      </section>
    </div>
  )
}
