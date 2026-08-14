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
