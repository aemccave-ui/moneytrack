function flowLabel(value) {
  return value === 'income' ? 'Приход' : 'Расход'
}

export default function CategoryTree({ rows, busyId, onEdit, onMove, onDelete }) {
  if (!rows.length) return <div className="settingsCategoryEmpty">Категорий пока нет</div>

  return (
    <div className="categoryTree" role="tree" aria-label="Категории">
      {rows.map(({ category, depth, canMoveUp, canMoveDown }) => {
        const busy = String(busyId || '') === String(category.id)
        return (
          <article className="categoryTreeRow" style={{ '--category-depth': depth }} role="treeitem" aria-level={depth + 1} key={category.id}>
            <span className="categoryTreeBranch" aria-hidden="true">{depth ? '└' : '•'}</span>
            <button type="button" className="categoryTreeIdentity" onClick={() => onEdit(category)} disabled={busy}>
              <strong>{category.name || category.code}</strong>
              <small>{category.code}</small>
            </button>
            <span className={`categoryFlowBadge ${category.flow_type === 'income' ? 'income' : 'expense'}`}>{flowLabel(category.flow_type)}</span>
            <div className="categoryTreeActions">
              <button type="button" onClick={() => onMove(category, 'up')} disabled={busy || !canMoveUp} aria-label={`Переместить ${category.name || category.code} выше`}>↑</button>
              <button type="button" onClick={() => onMove(category, 'down')} disabled={busy || !canMoveDown} aria-label={`Переместить ${category.name || category.code} ниже`}>↓</button>
              <button type="button" onClick={() => onEdit(category)} disabled={busy} aria-label={`Изменить ${category.name || category.code}`}>✎</button>
              <button type="button" className="danger" onClick={() => onDelete(category)} disabled={busy} aria-label={`Удалить ${category.name || category.code}`}>×</button>
            </div>
          </article>
        )
      })}
    </div>
  )
}
