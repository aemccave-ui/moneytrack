import { LabBottomNavigation } from '../../packages/lab-design-system/navigation.jsx'

export default function BudgetsScreen({ navigation }) {
  return (
    <main key="budgets" className="app screenPlaceholderPage">
      <section className="screenPlaceholderCard" aria-labelledby="budgets-screen-title">
        <span>Бюджеты</span>
        <h2 id="budgets-screen-title">Бюджеты</h2>
        <p>Экран выделен в отдельный JSX-контур. Реализация бюджетов остаётся в своём продуктном этапе.</p>
      </section>
      <LabBottomNavigation items={navigation} activeId="budgets" />
    </main>
  )
}
