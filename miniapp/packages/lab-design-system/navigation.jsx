const iconProps = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
  focusable: 'false',
  'aria-hidden': true,
}

export function LabNavIcon({ name }) {
  if (name === 'home') {
    return <svg {...iconProps}><path d="M3.5 10.5 12 3.5l8.5 7"/><path d="M5.5 9.5v10.5h13V9.5"/><path d="M9.5 20v-5.5h5V20"/></svg>
  }
  if (name === 'accounts') {
    return <svg {...iconProps}><rect x="3.5" y="5.5" width="17" height="13" rx="2.5"/><path d="M3.5 9.5h17"/><path d="M7 14.5h3.5"/></svg>
  }
  if (name === 'budgets') {
    return <svg {...iconProps}><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5V12h8.5"/></svg>
  }
  if (name === 'stats') {
    return <svg {...iconProps}><path d="M5 20V12"/><path d="M10 20V7"/><path d="M15 20V4"/><path d="M20 20v-6"/></svg>
  }
  return <svg {...iconProps}><circle cx="12" cy="12" r="3"/><path d="M19.2 13.8a7.5 7.5 0 0 0 0-3.6l2-1.15-2-3.45-2 1.15a7.7 7.7 0 0 0-3.1-1.8V2.7h-4v2.25a7.7 7.7 0 0 0-3.1 1.8L5 5.6 3 9.05l2 1.15a7.5 7.5 0 0 0 0 3.6L3 14.95 5 18.4l2-1.15a7.7 7.7 0 0 0 3.1 1.8v2.25h4v-2.25a7.7 7.7 0 0 0 3.1-1.8l2 1.15 2-3.45Z"/></svg>
}

export function LabBottomNavigation({ items, activeId, ariaLabel = 'Основная навигация' }) {
  return (
    <nav className="labBottomNav" aria-label={ariaLabel}>
      {items.map((item) => (
        <button
          type="button"
          key={item.id}
          className={`labBottomNavItem ${item.id === activeId ? 'isActive' : ''}`}
          aria-current={item.id === activeId ? 'page' : undefined}
          onClick={item.onClick}
        >
          <LabNavIcon name={item.icon} />
          <span>{item.label}</span>
        </button>
      ))}
    </nav>
  )
}
