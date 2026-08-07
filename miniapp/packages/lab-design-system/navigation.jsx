const iconProps = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.75,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
  focusable: 'false',
  'aria-hidden': true,
}

export function LabNavIcon({ name }) {
  if (name === 'home') {
    return <svg {...iconProps}><path d="M4 10.5 12 4l8 6.5"/><path d="M5.5 9.8V20h13V9.8"/><path d="M9.5 20v-5.2h5V20"/></svg>
  }
  if (name === 'accounts') {
    return <svg {...iconProps}><rect x="3.5" y="6" width="17" height="12" rx="2.4"/><path d="M3.5 10h17"/><path d="M7 14.5h3.2"/></svg>
  }
  if (name === 'budgets') {
    return <svg {...iconProps}><path d="M12 3.5a8.5 8.5 0 1 0 8.5 8.5H12Z"/><path d="M12 3.5V12h8.5"/></svg>
  }
  if (name === 'stats') {
    return <svg {...iconProps}><path d="M4.5 20V13"/><path d="M9.5 20V9"/><path d="M14.5 20V5"/><path d="M19.5 20v-8"/></svg>
  }
  return <svg {...iconProps}><circle cx="12" cy="12" r="3"/><path d="M19.2 13.8a7.5 7.5 0 0 0 0-3.6l1.9-1.1-2-3.4-1.9 1.1a7.6 7.6 0 0 0-3.1-1.8V2.8h-4V5a7.6 7.6 0 0 0-3.1 1.8L5.1 5.7l-2 3.4L5 10.2a7.5 7.5 0 0 0 0 3.6l-1.9 1.1 2 3.4L7 17.2a7.6 7.6 0 0 0 3.1 1.8v2.2h4V19a7.6 7.6 0 0 0 3.1-1.8l1.9 1.1 2-3.4Z"/></svg>
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
