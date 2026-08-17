import { useEffect, useMemo, useState } from 'react'
import { LabBottomNavigation } from '../../packages/lab-design-system/navigation.jsx'
import { getTransactionReference, updateCategory } from '../api.js'
import SecuritySettings from '../SecuritySettings.jsx'
import '../settings-categories.css'

const flowOf = (category) => {
  const value = String(category?.flow_type || '').toLowerCase()
  return value === 'income' || value === 'expense' ? value : ''
}

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

function CategorySettingsRow({ category, backendReady, onSaved }) {
  const sourceFlow = flowOf(category)
  const [name, setName] = useState(category.name || category.code || '')
  const [flowType, setFlowType] = useState(sourceFlow)
  const [saving, setSaving] = useState(false)
  const editable = backendReady && category.editable === true
  const changed = name.trim() !== String(category.name || category.code || '').trim()
    || flowType !== sourceFlow

  const save = async () => {
    if (!editable || !changed || !name.trim() || !flowType || saving) return
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
        <small>{category.code}{!editable ? ' · только чтение' : ''}</small>
      </div>
      <select aria-label={`Тип категории ${category.name || category.code}`} value={flowType} onChange={(event) => setFlowType(event.target.value)} disabled={!editable}>
        {!sourceFlow && <option value="">Не задан</option>}
        <option value="expense">Расход</option>
        <option value="income">Приход</option>
      </select>
      <button type="button" onClick={save} disabled={!editable || !changed || saving || !name.trim() || !flowType}>{saving ? '…' : '✓'}</button>
    </div>
  )
}

function SettingsSectionToggle({ id, title, meta, open, onClick }) {
  return (
    <button type="button" className="settingsSectionToggle" onClick={onClick} aria-expanded={open} aria-controls={`${id}-settings-section`}>
      <span className={`settingsSectionChevron ${open ? 'expanded' : ''}`} aria-hidden="true">›</span>
      <strong>{title}</strong>
      <span className="settingsSectionMeta">{meta}</span>
    </button>
  )
}

export default function SettingsScreen({ navigation }) {
  const [openSection, setOpenSection] = useState(null)
  const [categories, setCategories] = useState([])
  const [categoriesLoaded, setCategoriesLoaded] = useState(false)
  const [loadingCategories, setLoadingCategories] = useState(false)

  const toggleSection = (section) => setOpenSection((current) => current === section ? null : section)

  useEffect(() => {
    if (openSection !== 'categories' || categoriesLoaded || loadingCategories) return undefined
    const controller = new AbortController()
    setLoadingCategories(true)
    getTransactionReference(controller.signal)
      .then((result) => {
        setCategories(result?.categories || [])
        setCategoriesLoaded(true)
      })
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить категории')
      })
      .finally(() => setLoadingCategories(false))
    return () => controller.abort()
  }, [categoriesLoaded, loadingCategories, openSection])

  const rows = useMemo(() => flattenCategories(categories), [categories])
  const backendReady = categories.length === 0 || categories.every((category) => (
    typeof category.editable === 'boolean'
  ))

  const updateLocal = (updated) => setCategories((current) => current.map((item) => (
    String(item.id) === String(updated.id) ? { ...item, ...updated } : item
  )))

  return (
    <main key="settings" className="app settingsPage">
      <header className="settingsPageHeader">
        <span>Настройки</span>
        <h2>Настройки</h2>
      </header>

      <section className="settingsSectionCard">
        <SettingsSectionToggle
          id="security"
          title="Управление защитой"
          meta="PIN и биометрия"
          open={openSection === 'security'}
          onClick={() => toggleSection('security')}
        />
        {openSection === 'security' && (
          <div className="settingsSectionBody" id="security-settings-section">
            <SecuritySettings />
          </div>
        )}
      </section>

      <section className="settingsSectionCard">
        <SettingsSectionToggle
          id="categories"
          title="Управление категориями"
          meta={categoriesLoaded ? `${categories.length}` : 'Справочник'}
          open={openSection === 'categories'}
          onClick={() => toggleSection('categories')}
        />
        {openSection === 'categories' && (
          <div className="settingsSectionBody settingsCategorySection" id="categories-settings-section">
            <p className="settingsCategoryHint">Для каждой категории задаётся один финансовый тип. Полный CRUD и управление иерархией добавляются в UX-025B поверх Space-owned backend.</p>
            {!loadingCategories && !backendReady && <div className="settingsBackendNotice" role="status">Редактирование включится после применения backend-миграции справочника категорий. Текущие данные не изменяются.</div>}
            <div className="settingsCategoryHead"><span>Категория</span><span>Приход / расход</span><span /></div>
            <div className="settingsCategoryList">
              {loadingCategories && <div className="settingsCategoryEmpty">Загрузка…</div>}
              {!loadingCategories && categoriesLoaded && !rows.length && <div className="settingsCategoryEmpty">Категорий пока нет</div>}
              {rows.map((category) => <CategorySettingsRow key={category.id} category={category} backendReady={backendReady} onSaved={updateLocal} />)}
            </div>
          </div>
        )}
      </section>

      <LabBottomNavigation items={navigation} activeId="settings" />
    </main>
  )
}
