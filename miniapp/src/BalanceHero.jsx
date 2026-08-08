export function BalanceHero({
  label,
  result,
  income,
  expense,
  privacy,
  baseCurrency,
  money,
  className = '',
}) {
  const hidden = (value) => privacy
    ? '••••••'
    : money(value, baseCurrency)

  const resultText = hidden(result)
  const incomeText = hidden(income)
  const expenseText = hidden(expense)

  const sizeClass = (value) => {
    const length = String(value || '').length
    if (length >= 15) return 'isVeryLong'
    if (length >= 11) return 'isLong'
    return ''
  }

  return (
    <section
      className={`hero compactHero ${className}`.trim()}
      aria-label={label}
    >
      <div className="heroOrb heroOrbOne" />
      <div className="heroOrb heroOrbTwo" />

      {label && <span className="heroMonth">{label}</span>}

      <div className="heroMetricRow">
        <div className="heroMetric resultMetric">
          <span>Сальдо</span>
          <strong
            className={`sensitive ${sizeClass(resultText)}`.trim()}
          >
            {resultText}
          </strong>
        </div>

        <div className="heroMetric incomeMetric">
          <span>Доход</span>
          <strong
            className={`sensitive ${sizeClass(incomeText)}`.trim()}
          >
            {incomeText}
          </strong>
        </div>

        <div className="heroMetric expenseMetric">
          <span>Расход</span>
          <strong
            className={`sensitive ${sizeClass(expenseText)}`.trim()}
          >
            {expenseText}
          </strong>
        </div>
      </div>
    </section>
  )
}
