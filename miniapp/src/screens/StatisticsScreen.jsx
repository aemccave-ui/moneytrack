import { LabBottomNavigation } from '../../packages/lab-design-system/navigation.jsx'

export default function StatisticsScreen({ navigation }) {
  return (
    <main key="stats" className="app screenPlaceholderPage">
      <section className="screenPlaceholderCard" aria-labelledby="statistics-screen-title">
        <span>Статистика</span>
        <h2 id="statistics-screen-title">Статистика</h2>
        <p>Экран выделен в отдельный JSX-контур. Аналитическая реализация остаётся в своём продуктном этапе.</p>
      </section>
      <LabBottomNavigation items={navigation} activeId="stats" />
    </main>
  )
}
