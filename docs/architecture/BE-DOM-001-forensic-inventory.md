# MoneyTrack — BE-DOM-001 — Forensic Inventory

## Status

FORENSIC BASELINE ESTABLISHED

## Scope

This inventory records finance/domain logic that is currently visible in repository-owned n8n workflow definitions and MiniApp compatibility code. It is evidence for extraction; it is not a redesign of financial meaning.

Primary workflow inspected:

- `workflows/moneytrack-miniapp-api-7TJ2xQTxLsTydXZc.json`

## Confirmed persistence objects

The current MiniApp API workflow directly references at least:

- `moneytrack.app_users`
- `moneytrack.user_settings`
- `moneytrack.workspaces`
- `moneytrack.accounts`
- `moneytrack.transactions`
- `moneytrack.user_default_accounts`
- `moneytrack.exchange_rates_usd`

Other exported workflows also reference product/category persistence, but those are outside the first finance extraction slice.

## Current ownership map

| Concern | Current implementation | Classification | Target owner |
|---|---|---|---|
| Resolve Telegram caller to internal user | n8n SQL | Adapter / identity | API adapter |
| Select base/report currency | n8n SQL | Application context | application/read-model entry point |
| Account balance in original currency | `sum(transactions.amount_original)` in n8n SQL | Finance read model | PostgreSQL finance read model |
| Account balance in stored base currency | `sum(transactions.amount_base)` in n8n SQL | Finance read model | PostgreSQL finance read model |
| Default account for base currency | join to `user_default_accounts` in n8n SQL | Application/read model | PostgreSQL finance read model |
| Monthly income | transaction type + FX conversion in n8n SQL | Finance read model | PostgreSQL finance read model using canonical FX rule |
| Monthly expense | `expense` + `abs(amount_report)` in n8n SQL | Finance semantics/read model | PostgreSQL finance read model |
| Monthly result | income - expenses in n8n SQL | Finance read model | PostgreSQL finance read model |
| FX conversion | latest `exchange_rates_usd` rates on/before valuation date; USD bridge formula | Finance domain service | canonical PostgreSQL finance function |
| Net worth | account balances converted to report currency | Finance read model | PostgreSQL finance read model |
| Latest operations | n8n SQL JSON aggregation | Read model | PostgreSQL read model or thin query |
| Account tree construction | n8n JS | Response shaping | adapter/application presentation mapping; not finance canonical logic |
| Numeric JSON coercion | n8n JS | Transport mapping | adapter |
| Multi-name default-account fallbacks | MiniApp JS | Compatibility debt | remove after API contract stabilization |

## Existing financial semantics that must be preserved during extraction

### Account endpoint

The current accounts query computes:

```text
balance_original = SUM(transactions.amount_original)
balance_base     = SUM(transactions.amount_base)
total_base       = SUM(account balance_base)
```

Only active accounts are included.

Default account is selected from `user_default_accounts` for the user's base currency.

This means the accounts endpoint currently trusts stored `amount_base` values. BE-DOM-001 must not silently replace this with current-rate revaluation.

### Dashboard period summary

The current dashboard uses the calendar month containing the evaluation date.

For each transaction it obtains:

- the latest source-currency USD rate on or before `transaction_date`;
- the latest report-currency USD rate on or before `transaction_date`.

Existing conversion formula:

```text
amount_report = amount_original * report_currency_usd_rate / source_currency_usd_rate
```

The extraction must reproduce that formula exactly until FX semantics are separately validated.

Monthly income includes rows where `transaction_type = 'income'`.

Monthly expense includes rows where `transaction_type = 'expense'` and uses `abs(amount_report)`.

Monthly result is:

```text
income_month - expenses_month
```

### Net worth

The current dashboard first sums transaction original amounts by active-account currency and then revalues each currency balance to report currency using the latest available rate on or before the evaluation date.

This is intentionally different from the accounts endpoint, which sums stored `amount_base`.

The difference is existing behavior and is not to be normalized inside BE-DOM-001 without a dedicated finance decision.

### Latest operations

The current dashboard returns the latest 10 transactions ordered by:

```text
transaction_date DESC, id DESC
```

The list is not restricted to the dashboard month.

## Confirmed architecture debt

### D-001 — Financial SQL embedded in n8n

Severity: HIGH

Account balances, monthly totals, FX conversion and net worth are currently implemented inside the n8n workflow definition. Replacing n8n would therefore require reimplementing financial read semantics.

Action: extract these formulas to versioned PostgreSQL entry points.

### D-002 — Two valuation concepts are implicit

Severity: HIGH

`amount_base` aggregation and report-currency revaluation are different concepts but are currently exposed without an explicit valuation policy abstraction.

Action: preserve both in BE-DOM-001 and document their meaning. A later finance decision may introduce explicit historical/base/report valuation policies.

### D-003 — FX bridge convention is implicit

Severity: HIGH

The meaning/orientation of `exchange_rates_usd.usd_rate` is encoded only through the SQL formula.

Action: centralize the existing formula behind a canonical function. Do not invert or reinterpret rates during extraction.

### D-004 — Missing-rate behavior is implicit

Severity: MEDIUM

When either FX leg is missing, converted amount is `NULL`. Aggregate `SUM` then ignores such rows; if every row is NULL, aggregate-level `COALESCE` can yield zero.

This can make missing valuation data look like zero financial activity/value.

Action: preserve behavior for compatibility in the first extraction, but mark explicit missing-rate handling as a required follow-up before treating financial reports as audit-grade.

### D-005 — Dashboard net worth does not apply an explicit transaction as-of filter

Severity: MEDIUM

The balance CTE sums all persisted transactions and only uses the evaluation date for the FX rate. If future-dated transactions exist, they can contribute to net worth.

Action: preserve for parity in BE-DOM-001. Decide separately whether portfolio valuation should filter `transaction_date <= as_of`.

### D-006 — UI contains API-shape recovery logic

Severity: MEDIUM

The MiniApp recognizes multiple spellings/locations for default-account configuration and may locally infer the selected account.

Action: keep compatibility during extraction, then collapse to one versioned API response contract.

## First extraction slice

The first slice is read-only and consists of three PostgreSQL entry points:

1. canonical legacy-compatible USD-bridge conversion;
2. accounts read model;
3. dashboard read model.

The functions accept internal `user_id`, not Telegram identity. Caller identity resolution remains an adapter responsibility.

The dashboard read model accepts an explicit `as_of` date so finance calculations are deterministic for persisted state + inputs and are independently testable outside n8n.

## Cutover rule

Do not remove the existing n8n queries immediately.

Required sequence:

```text
legacy n8n query
    ↓
new PostgreSQL read-model function
    ↓
parity comparison on representative users/dates
    ↓
n8n switches to function call
    ↓
API response parity verification
    ↓
embedded financial SQL removed
```

## Out of scope for this slice

The following are deliberately not changed yet:

- transaction creation/update/delete;
- transfer posting semantics;
- duplicate/idempotency rules;
- receipt posting;
- category mutation;
- account mutation;
- database schema redesign;
- introduction of a standalone backend service.

Those require a write-path invariant inventory after the read-model baseline is proven.