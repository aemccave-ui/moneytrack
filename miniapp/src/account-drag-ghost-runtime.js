let timer = null
let ghost = null
let sourceShell = null
let startX = 0
let startY = 0
let offsetX = 0
let offsetY = 0
let active = false

function clearTimer() {
  if (timer != null) window.clearTimeout(timer)
  timer = null
}

function removeGhost() {
  clearTimer()
  ghost?.remove()
  ghost = null
  sourceShell = null
  active = false
}

function positionGhost(x, y) {
  if (!ghost) return
  ghost.style.setProperty('--drag-x', `${x - offsetX}px`)
  ghost.style.setProperty('--drag-y', `${y - offsetY}px`)
}

document.addEventListener('touchstart', (event) => {
  if (event.touches.length !== 1) return
  const row = event.target.closest?.('.accountTreeRow')
  const node = row?.closest?.('.accountTreeNode')
  const shell = node?.querySelector?.(':scope > .accountSwipeShell')
  if (!row || !node || !shell) return
  if (event.target.closest('.accountSelectionControl, .accountDisclosureControl, .swipeActionButton')) return
  if ((shell.scrollLeft || 0) > 4) return

  const touch = event.touches[0]
  startX = touch.clientX
  startY = touch.clientY
  sourceShell = shell
  const rect = shell.getBoundingClientRect()
  offsetX = touch.clientX - rect.left
  offsetY = touch.clientY - rect.top
  clearTimer()
  timer = window.setTimeout(() => {
    if (!sourceShell) return
    const currentRect = sourceShell.getBoundingClientRect()
    ghost = sourceShell.cloneNode(true)
    ghost.className = 'accountDragGhost'
    ghost.removeAttribute('style')
    ghost.querySelectorAll('[id]').forEach((element) => element.removeAttribute('id'))
    ghost.querySelectorAll('button').forEach((button) => { button.disabled = true; button.tabIndex = -1 })
    ghost.style.width = `${currentRect.width}px`
    ghost.style.height = `${currentRect.height}px`
    document.body.appendChild(ghost)
    active = true
    positionGhost(startX, startY)
  }, 480)
}, { passive: true, capture: true })

document.addEventListener('touchmove', (event) => {
  const touch = event.touches[0]
  if (!touch) return
  if (!active) {
    if (Math.abs(touch.clientX - startX) > 8 || Math.abs(touch.clientY - startY) > 8) clearTimer()
    return
  }
  positionGhost(touch.clientX, touch.clientY)
}, { passive: true, capture: true })

document.addEventListener('touchend', removeGhost, { passive: true, capture: true })
document.addEventListener('touchcancel', removeGhost, { passive: true, capture: true })
