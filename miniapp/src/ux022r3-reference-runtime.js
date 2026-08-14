import { accountTypeOptions } from './reference-options.js'

function setReactInputValue(input, value) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
  if (setter) setter.call(input, value)
  else input.value = value
  input.dispatchEvent(new Event('input', { bubbles: true }))
  input.dispatchEvent(new Event('change', { bubbles: true }))
}

function enhanceAccountTypeEditor() {
  document.querySelectorAll('.accountSheet label').forEach((label) => {
    const labelText = label.querySelector(':scope > span')?.textContent?.trim()
    const input = label.querySelector(':scope > input')
    if (labelText !== 'Тип' || !input || input.dataset.accountTypeReference === 'true') return

    input.dataset.accountTypeReference = 'true'
    input.classList.add('accountTypeSourceInput')

    const select = document.createElement('select')
    select.className = 'accountTypeReferenceSelect'
    select.setAttribute('aria-label', 'Тип счёта')
    accountTypeOptions(input.value).forEach((option) => {
      const node = document.createElement('option')
      node.value = option.value
      node.textContent = option.label
      select.appendChild(node)
    })
    select.value = input.value
    select.addEventListener('change', () => setReactInputValue(input, select.value))
    label.appendChild(select)
  })
}

function enhanceSummaryCountBadges() {
  document.querySelectorAll('.stackNamedCaption').forEach((caption) => {
    const items = caption.querySelectorAll(':scope > .stackNamedItem')
    if (!items.length) return
    let badge = caption.querySelector(':scope > .summaryCountBadge')
    if (!badge) {
      badge = document.createElement('span')
      badge.className = 'homeCountBadge compactCountBadge summaryCountBadge'
      caption.prepend(badge)
    }
    const count = String(items.length)
    if (badge.textContent !== count) badge.textContent = count
    badge.setAttribute('aria-label', `Элементов: ${count}`)
  })
}

function enhance() {
  enhanceAccountTypeEditor()
  enhanceSummaryCountBadges()
}

const observer = new MutationObserver(() => window.requestAnimationFrame(enhance))
observer.observe(document.body, { childList: true, subtree: true })
window.requestAnimationFrame(enhance)
