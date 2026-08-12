import { useEffect, useMemo, useState } from 'react'
import {
  createFilterPreset,
  deleteFilterPreset,
  getFilterPresets,
  getTransactionReference,
  renameFilterPreset,
} from './api.js'
import './accounts-filters.css'

const normalizeIds = (values = []) => [...new Set(values.map(String))]
  .sort((a, b) => Number(a) - Number(b))

const sameIds = (left = [], right = []) => {
  const a = normalizeIds(left)
  const b = normalizeIds(right)
  return a.length === b.length && a.every((value, index) => value === b[index])
}

const categoryFlow = (category) => {
  const value = String(category?.flow_type || '').toLowerCase()
  return value === 'income' || value === 'expense' ? value : null
}

function flattenCategories(items = []) {
  const byId = new Map(items.map((item) => [String(item.id), { item, children: [] }]))
  const roots = []
  byId.forEach((node) => {
    const parent = node.item.parent_id == null ? null : byId.get(String(node.item.parent_id))
    if (parent && parent !== node) parent.children.push(node)
    else roots.push(node)
  })
  const compare = (a, b) => {
    const order = Number(a.item.sort_order || 0) - Number(b.item.sort_order || 0)
    if (order) return order
    return String(a.item.name || a.item.code || '').localeCompare(String(b.item.name || b.item.code || ''), 'ru')
  }
  const rows = []
  const visit = (node, depth) => {
    rows.push({ ...node.item, depth })
    node.children.sort(compare).forEach((child) => visit(child, depth + 1))
  }
  roots.sort(compare).forEach((node) => visit(node, 0))
  return rows
}

function confirmAction(message) {
  if (window.Telegram?.WebApp?.showConfirm) {
    return new Promise((resolve) => window.Telegram.WebApp.showConfirm(message, resolve))
  }
  return Promise.resolve(window.confirm(message))
}

function promptText(message, initial = '') {
  return String(window.prompt(message, initial) || '').trim()
}

function showError(message) {
  if (window.Telegram?.WebApp?.showAlert) window.Telegram.WebApp.showAlert(message)
  else window.alert(message)
}

function Sheet({ title, onClose, children, footer }) {
  return (
    <div className="accountsFilterBackdrop" role="presentation" onClick={(event) => event.target === event.currentTarget && onClose()}>
      <section className="accountsFilterSheet" role="dialog" aria-modal="true" aria-label={title}>
        <header><strong>{title}</strong><button type="button" onClick={onClose} aria-label="Закрыть">×</button></header>
        <div className="accountsFilterSheetBody">{children}</div>
        {footer && <footer>{footer}</footer>}
      </section>
    </div>
  )
}

export default function AccountsFilters({
  allAccountIds,
  selectedAccountIds,
  incomeCategoryIds,
  expenseCategoryIds,
  onApplySelectedAccounts,
  onApplyCategories,
  onResetAll,
}) {
  const [categories, setCategories] = useState([])
  const [presets, setPresets] = useState([])
  const [loading, setLoading] = useState(true)
  const [sheet, setSheet] = useState(null)
  const [draftCategories, setDraftCategories] = useState(new Set())

  const categoryRows = useMemo(() => flattenCategories(categories), [categories])
  const allCategoryIds = useMemo(() => normalizeIds(categories.map((item) => item.id)), [categories])
  const flowMetadataReady = categories.length === 0 || categories.every((item) => categoryFlow(item) != null)
  const allIncomeIds = useMemo(
    () => flowMetadataReady
      ? normalizeIds(categories.filter((item) => categoryFlow(item) === 'income').map((item) => item.id))
      : allCategoryIds,
    [allCategoryIds, categories, flowMetadataReady],
  )
  const allExpenseIds = useMemo(
    () => flowMetadataReady
      ? normalizeIds(categories.filter((item) => categoryFlow(item) === 'expense').map((item) => item.id))
      : allCategoryIds,
    [allCategoryIds, categories, flowMetadataReady],
  )
  const effectiveIncomeIds = incomeCategoryIds == null ? allIncomeIds : normalizeIds(incomeCategoryIds)
  const effectiveExpenseIds = expenseCategoryIds == null ? allExpenseIds : normalizeIds(expenseCategoryIds)
  const effectiveCategoryIds = useMemo(
    () => normalizeIds([...effectiveIncomeIds, ...effectiveExpenseIds]),
    [effectiveExpenseIds, effectiveIncomeIds],
  )

  const reloadPresets = async (signal) => {
    const result = await getFilterPresets(signal)
    setPresets(result?.presets || [])
  }

  useEffect(() => {
    const controller = new AbortController()
    Promise.all([
      getTransactionReference(controller.signal),
      getFilterPresets(controller.signal),
    ])
      .then(([reference, presetData]) => {
        setCategories(reference?.categories || [])
        setPresets(presetData?.presets || [])
      })
      .catch((error) => {
        if (error?.name !== 'AbortError') showError(error?.message || 'Не удалось загрузить фильтры')
      })
      .finally(() => setLoading(false))
    return () => controller.abort()
  }, [])

  const allActive = sameIds(selectedAccountIds, allAccountIds)
    && sameIds(effectiveCategoryIds, allCategoryIds)

  const activePresetId = useMemo(() => {
    const match = presets.find((preset) => (
      sameIds(selectedAccountIds, preset.account_ids || [])
      && sameIds(effectiveIncomeIds, preset.income_category_ids || [])
      && sameIds(effectiveExpenseIds, preset.expense_category_ids || [])
    ))
    return match?.id == null ? null : String(match.id)
  }, [effectiveExpenseIds, effectiveIncomeIds, presets, selectedAccountIds])

  const categorySummary = !flowMetadataReady
    ? 'Нужно обновить справочник'
    : allCategoryIds.length === 0 || sameIds(effectiveCategoryIds, allCategoryIds)
      ? 'Все'
      : `${effectiveCategoryIds.length} из ${allCategoryIds.length}`

  const openCategories = () => {
    if (!flowMetadataReady) return
    setDraftCategories(new Set(effectiveCategoryIds))
    setSheet('categories')
  }

  const toggleDraft = (id) => setDraftCategories((current) => {
    const next = new Set(current)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    return next
  })

  const applyCategories = () => {
    if (!flowMetadataReady) return
    const selected = new Set([...draftCategories].map(String))
    onApplyCategories({
      incomeCategoryIds: normalizeIds(categories
        .filter((item) => categoryFlow(item) === 'income' && selected.has(String(item.id)))
        .map((item) => item.id)),
      expenseCategoryIds: normalizeIds(categories
        .filter((item) => categoryFlow(item) === 'expense' && selected.has(String(item.id)))
        .map((item) => item.id)),
    })
    setSheet(null)
  }

  const applyPreset = (preset) => {
    onApplySelectedAccounts(normalizeIds(preset.account_ids || []))
    onApplyCategories({
      incomeCategoryIds: normalizeIds(preset.income_category_ids || []),
      expenseCategoryIds: normalizeIds(preset.expense_category_ids || []),
    })
    setSheet(null)
  }

  const savePreset = async () => {
    const name = promptText('Название нового пресета')
    if (!name) return
    try {
      await createFilterPreset({
        name,
        accountIds: normalizeIds(selectedAccountIds),
        incomeCategoryIds: effectiveIncomeIds,
        expenseCategoryIds: effectiveExpenseIds,
      })
      await reloadPresets()
    } catch (error) {
      showError(error?.message || 'Не удалось сохранить пресет')
    }
  }

  const renamePreset = async (preset) => {
    const name = promptText('Новое название', preset.name || '')
    if (!name || name === preset.name) return
    try {
      await renameFilterPreset(preset.id, name)
      await reloadPresets()
    } catch (error) {
      showError(error?.message || 'Не удалось переименовать пресет')
    }
  }

  const removePreset = async (preset) => {
    if (!(await confirmAction(`Удалить пресет «${preset.name}»?`))) return
    try {
      await deleteFilterPreset(preset.id)
      await reloadPresets()
    } catch (error) {
      showError(error?.message || 'Не удалось удалить пресет')
    }
  }

  return (
    <>
      <div className="accountsFilterActions">
        <button type="button" className="accountsFilterAction" onClick={openCategories} disabled={loading || !flowMetadataReady} title={!flowMetadataReady ? 'Требуется backend flow_type' : undefined}>
          <span className="accountsFilterIcon" aria-hidden="true">◉</span>
          <span><strong>Категории</strong><small>{loading ? 'Загрузка…' : categorySummary}</small></span>
          <span className="accountsFilterChevron" aria-hidden="true">›</span>
        </button>
        <button type="button" className="accountsFilterAction" onClick={() => setSheet('presets')} disabled={loading}>
          <span className="accountsFilterIcon" aria-hidden="true">◇</span>
          <span><strong>Пресеты</strong><small>{loading ? 'Загрузка…' : `${presets.length + 1} · Сохранить`}</small></span>
          <span className="accountsFilterChevron" aria-hidden="true">›</span>
        </button>
      </div>

      {sheet === 'categories' && flowMetadataReady && (
        <Sheet
          title="Категории"
          onClose={() => setSheet(null)}
          footer={<button type="button" className="accountsFilterPrimary" onClick={applyCategories}>Применить</button>}
        >
          <div className="categoryMatrixHeader single"><span>Категория</span><span>Выбрано</span></div>
          <div className="categoryMatrixActions">
            <button type="button" onClick={() => setDraftCategories(new Set(allCategoryIds))}>Выбрать все</button>
            <button type="button" onClick={() => setDraftCategories(new Set())}>Очистить</button>
          </div>
          <div className="categoryMatrix single">
            {categoryRows.map((category) => {
              const id = String(category.id)
              const enabled = draftCategories.has(id)
              return (
                <div className="categoryMatrixRow single" key={id} style={{ '--category-depth': category.depth || 0 }}>
                  <span className="categoryMatrixName"><span>{category.name || category.code}</span><small>{categoryFlow(category) === 'income' ? 'Приход' : 'Расход'}</small></span>
                  <button type="button" className={`categoryCircle ${enabled ? 'isOn' : ''}`} onClick={() => toggleDraft(id)} aria-label={`${category.name || category.code}: ${enabled ? 'выбрано' : 'не выбрано'}`} aria-pressed={enabled}><span /></button>
                </div>
              )
            })}
          </div>
        </Sheet>
      )}

      {sheet === 'presets' && (
        <Sheet
          title="Пресеты"
          onClose={() => setSheet(null)}
          footer={<button type="button" className="accountsFilterPrimary" onClick={savePreset}>+ Сохранить текущие выборки</button>}
        >
          <div className="presetList">
            <button type="button" className={`presetRow presetSystem ${allActive ? 'isActive' : ''}`} onClick={() => { onResetAll(); setSheet(null) }}>
              <span><strong>Все</strong><small>Системный пресет</small></span><b>{allActive ? '✓' : ''}</b>
            </button>
            {presets.map((preset) => (
              <div className={`presetRow ${String(preset.id) === activePresetId ? 'isActive' : ''}`} key={preset.id}>
                <button type="button" className="presetApply" onClick={() => applyPreset(preset)}>
                  <span><strong>{preset.name}</strong><small>{(preset.account_ids || []).length} сч. · {normalizeIds([...(preset.income_category_ids || []), ...(preset.expense_category_ids || [])]).length} кат.</small></span>
                  <b>{String(preset.id) === activePresetId ? '✓' : ''}</b>
                </button>
                <button type="button" className="presetMiniAction" onClick={() => renamePreset(preset)} aria-label={`Переименовать ${preset.name}`}>✎</button>
                <button type="button" className="presetMiniAction danger" onClick={() => removePreset(preset)} aria-label={`Удалить ${preset.name}`}>×</button>
              </div>
            ))}
          </div>
        </Sheet>
      )}
    </>
  )
}
