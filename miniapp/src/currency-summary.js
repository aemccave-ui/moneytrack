const currencyFromTitle = (title = '') => title.split(':', 1)[0].trim()

const pluralCurrency = (count) => {
  const mod10 = count % 10
  const mod100 = count % 100
  if (mod10 === 1 && mod100 !== 11) return 'валюта'
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'валюты'
  return 'валют'
}

function fitCurrencyLabel(meta) {
  const label = meta.querySelector(':scope > span:first-child')
  const segments = [...document.querySelectorAll('.currencyStackSegment')]
  if (!label || !segments.length) return

  const currencies = segments
    .map((segment) => currencyFromTitle(segment.getAttribute('title')))
    .filter(Boolean)

  if (!currencies.length) return

  const full = currencies.join(' · ')
  label.textContent = full
  label.classList.add('currencyStackLabel')
  label.title = full

  if (label.scrollWidth <= label.clientWidth) return

  const suffix = `… (${currencies.length} ${pluralCurrency(currencies.length)})`
  let visible = currencies.length - 1

  while (visible > 0) {
    label.textContent = `${currencies.slice(0, visible).join(' · ')} · ${suffix}`
    if (label.scrollWidth <= label.clientWidth) return
    visible -= 1
  }

  label.textContent = suffix
}

/* UX022R3_HOME_COUNT_BADGE_RUNTIME */
function ensureCountBadge(button, segmentSelector, labelSelector, noun) {
  const label = button.querySelector(labelSelector)
  if (!label) return

  const count = button.querySelectorAll(segmentSelector).length
  let badge = label.querySelector('.stackCount')

  if (count <= 1) {
    if (badge?.dataset.runtimeCountBadge === 'true') badge.remove()
    return
  }

  if (!badge) {
    badge = document.createElement('span')
    badge.className = 'stackCount'
    badge.dataset.runtimeCountBadge = 'true'
    label.append(badge)
  }

  const next = String(count)
  if (badge.textContent !== next) badge.textContent = next
  badge.setAttribute('aria-label', `${noun}: ${count}`)
  badge.setAttribute('title', `${noun}: ${count}`)
}

function enhanceHomeCountBadges() {
  document.querySelectorAll('.currencyStackButton').forEach((button) => {
    ensureCountBadge(button, '.currencyStackSegment', '.stackCaption', 'Валют')
  })
  document.querySelectorAll('.accountStackButton').forEach((button) => {
    ensureCountBadge(button, '.accountStackSegment', '.accountStackMeta', 'Счетов')
  })
}

function enhanceCurrencySummary() {
  const meta = document.querySelector('.currencyStackMeta')
  if (meta) fitCurrencyLabel(meta)
  enhanceHomeCountBadges()
}

const observer = new MutationObserver(() => requestAnimationFrame(enhanceCurrencySummary))
observer.observe(document.documentElement, { childList: true, subtree: true })

window.addEventListener('resize', enhanceCurrencySummary, { passive: true })
requestAnimationFrame(enhanceCurrencySummary)
