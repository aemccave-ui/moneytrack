import { useEffect, useMemo, useState } from 'react'
import {
  createCategory,
  deleteCategory,
  editCategory,
  getCategoryDirectory,
  reorderCategory,
} from '../../category-directory-api.js'
import CategoryEditor from './CategoryEditor.jsx'
import CategoryTree from './CategoryTree.jsx'

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function confirmAction(message) {
  if (window.Telegram?.WebApp?.showConfirm) {
    return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  }
  return Promise.resolve(window.confirm(message))
}

function categoryRows(categories) {
  const byParent = new Map()
  categories.forEach((category) => {
    const parent = category.parent_id == null ? 'root' : String(category.parent_id)
    if (!byParent.has(parent)) byParent.set(parent, [])
    byParent.get(parent).push(category)
  })
  const sort = (a, b) => Number(a.sort_order || 0) - Number(b.sort_order || 0)
    || Number(a.id) - Number(b.id)
    || String(a.name || a.code || '').localeCompare(String(b.name || b.code || ''), 'ru')
  byParent.forEach((items) => items.sort(sort))

  const rows = []
  const visited = new Set()
  const visit = (parentKey, depth) => {
    const siblings = byParent.get(parentKey) || []
    siblings.forEach((category, index) => {
      const id = String(category.id)
      if (visited.has(id)) return
      visited.add(id)
      rows.push({
        category,
        depth,
        canMoveUp: index > 0,
        canMoveDown: index < siblings.length - 1,
      })
      visit(id, depth + 1)
    })
  }
  visit('root', 0)

  // Corrupt/orphaned topology remains visible instead of disappearing. The
  // backend refuses new cross-Space/cyclic topology, but this makes legacy
  // forensic anomalies recoverable from Settings.
  categories.filter((category) => !visited.has(String(category.id))).sort(sort).forEach((category) => {
    rows.push({ category, depth: 0, canMoveUp: false, canMoveDown: false })
  })
  return rows
}

export default function CategorySettings() {
  const [categories, setCategories] = useState([])
  const [loading, setLoading] = useState(true)
  const [editor, setEditor] = useState(null)
  const [busyId, setBusyId] = useState(null)

  const refresh = async (signal) => {
    const next = await getCategoryDirectory(signal)
    setCategories(next)
    return next
  }

  useEffect(() => {
    const controller = new AbortController()
    refresh(controller.signal)
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить категории')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [])

  const rows = useMemo(() => categoryRows(categories), [categories])

  const save = async (draft) => {
    if (busyId != null) return
    setBusyId(draft.categoryId || 'new')
    try {
      if (draft.categoryId == null) {
        await createCategory(draft)
      } else {
        await editCategory(draft)
      }
      await refresh()
      setEditor(null)
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить категорию')
    } finally {
      setBusyId(null)
    }
  }

  const move = async (category, direction) => {
    if (busyId != null) return
    setBusyId(category.id)
    try {
      await reorderCategory(category.id, direction)
      await refresh()
    } catch (error) {
      showError(error?.message || 'Не удалось изменить порядок категорий')
    } finally {
      setBusyId(null)
    }
  }

  const remove = async (category) => {
    if (busyId != null) return
    const confirmed = await confirmAction(`Удалить категорию «${category.name || category.code}»? Исторические операции сохранят категорию.`)
    if (!confirmed) return
    setBusyId(category.id)
    try {
      await deleteCategory(category.id)
      await refresh()
      if (String(editor?.id || '') === String(category.id)) setEditor(null)
    } catch (error) {
      const message = error?.code === 'CATEGORY_HAS_ACTIVE_CHILDREN'
        ? 'Сначала переместите или удалите дочерние категории.'
        : error?.message || 'Не удалось удалить категорию'
      showError(message)
    } finally {
      setBusyId(null)
    }
  }

  if (editor) {
    return (
      <CategoryEditor
        category={editor === 'new' ? null : editor}
        categories={categories}
        onCancel={() => setEditor(null)}
        onSave={save}
        busy={busyId != null}
      />
    )
  }

  return (
    <div className="categorySettings">
      <div className="categorySettingsToolbar">
        <div><strong>Категории</strong><span>{loading ? 'Загрузка…' : `${categories.length} активных`}</span></div>
        <button type="button" onClick={() => setEditor('new')} disabled={loading || busyId != null}>+ Добавить</button>
      </div>
      <p className="settingsCategoryHint">Категории принадлежат текущему пространству. Название, тип, родитель и порядок можно менять; удаление архивирует категорию и сохраняет историю.</p>
      {loading ? <div className="settingsCategoryEmpty">Загрузка…</div> : (
        <CategoryTree rows={rows} busyId={busyId} onEdit={setEditor} onMove={move} onDelete={remove} />
      )}
    </div>
  )
}
