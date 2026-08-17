import { useState } from 'react'
import { LabBottomNavigation } from '../../packages/lab-design-system/navigation.jsx'
import SecuritySettings from '../SecuritySettings.jsx'
import CategorySettings from './settings/CategorySettings.jsx'
import '../settings-categories.css'

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
  // Both Settings domains are intentionally collapsed on first entry. Opening
  // one replaces the other so long security/category forms never stack.
  const [openSection, setOpenSection] = useState(null)
  const toggleSection = (section) => setOpenSection((current) => current === section ? null : section)

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
          meta="Справочник"
          open={openSection === 'categories'}
          onClick={() => toggleSection('categories')}
        />
        {openSection === 'categories' && (
          <div className="settingsSectionBody settingsCategorySection" id="categories-settings-section">
            <CategorySettings />
          </div>
        )}
      </section>

      <LabBottomNavigation items={navigation} activeId="settings" />
    </main>
  )
}
