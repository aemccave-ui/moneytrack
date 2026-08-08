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

  return (
    <section
      className={`hero compactHero ${className}`.trim()}
      aria-label={label}
    >
      <div className="heroOrb heroOrbOne" />
      <div className="heroOrb heroOrbTwo" />

      <span className="heroMonth">{label}</span>

      <div className="heroMetricRow">
        <div className="heroMetric resultMetric">
          <span>Сальдо</span>
          <strong className="sensitive">
            {hidden(result)}
          </strong>
        </div>

        <div className="heroMetric incomeMetric">
          <span>
            <span className="glyph" aria-hidden="true">↑</span>
            Доход
          </span>
          <strong className="sensitive">
            {hidden(income)}
          </strong>
        </div>

        <div className="heroMetric expenseMetric">
          <span>
            <span className="glyph" aria-hidden="true">↓</span>
            Расход
          </span>
          <strong className="sensitive">
            {hidden(expense)}
          </strong>
        </div>
      </div>
    </section>
  )
}
