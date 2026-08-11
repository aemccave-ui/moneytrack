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

/* UX022R3_HOME_COUNT_BADGE_RUNTIME
   Counts are attached to each named Home aggregate, never to the whole stack.
   A count of 1 is valid and remains visible. */
function setCountBadge(badge, count, noun = 'Счетов') {
  badge.classList.add('homeCountBadge')
  const next = String(count)
  if (badge.textContent !== next) badge.textContent = next
  badge.setAttribute('aria-label', `${noun}: ${count}`)
  badge.setAttribute('title', `${noun}: ${count}`)
}

function enhanceCurrencyGroupBadges() {
  document.querySelectorAll('.currencyDistribution .currencyGroupHeader').forEach((button) => {
    const name = button.querySelector('.currencyBadge')
    const countNode = button.querySelector('.hierarchyCount, .homeCountBadge')
    if (!name || !countNode) return

    const match = countNode.textContent.match(/\d+/)
    if (!match) return

    setCountBadge(countNode, Number(match[0]))
  })
}

function enhanceHomeAccountBadges() {
  document.querySelectorAll('.accountDistribution .accountTreeRow.hasChildren').forEach((row) => {
    const identity = row.querySelector('.accountTreeIdentity')
    const title = identity?.querySelector(':scope > strong, :scope > .homeAggregateTitleRow > strong')
    const meta = identity?.querySelector(':scope > span:not(.homeAggregateTitleRow)')
    if (!identity || !title || !meta) return

    const match = meta.textContent.match(/(?:^|\s)·\s*(\d+)\s*$/)
    let count = match ? Number(match[1]) : null
    let titleRow = identity.querySelector(':scope > .homeAggregateTitleRow')
    let badge = titleRow?.querySelector(':scope > .homeCountBadge')

    if (count == null && badge) {
      const existing = badge.textContent.match(/\d+/)
      count = existing ? Number(existing[0]) : null
    }
    if (count == null) return

    if (!titleRow) {
      titleRow = document.createElement('span')
      titleRow.className = 'homeAggregateTitleRow'
      identity.insertBefore(titleRow, title)
      titleRow.append(title)
    }

    if (!badge) {
      badge = document.createElement('span')
      titleRow.append(badge)
    }
    setCountBadge(badge, count)

    if (match) {
      meta.textContent = meta.textContent.replace(/\s*·\s*\d+\s*$/, '').trim()
    }
  })
}

function enhanceCurrencySummary() {
  const meta = document.querySelector('.currencyStackMeta')
  if (meta) fitCurrencyLabel(meta)
  enhanceCurrencyGroupBadges()
  enhanceHomeAccountBadges()
}

const observer = new MutationObserver(() => requestAnimationFrame(enhanceCurrencySummary))
observer.observe(document.documentElement, { childList: true, subtree: true })

window.addEventListener('resize', enhanceCurrencySummary, { passive: true })
requestAnimationFrame(enhanceCurrencySummary)
