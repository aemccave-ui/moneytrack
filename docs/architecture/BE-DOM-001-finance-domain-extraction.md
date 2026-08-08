# MoneyTrack — BE-DOM-001 — Finance Domain Extraction

## Status

**IN PROGRESS — READ SLICE PASS / WRITE EXTRACTION PENDING**

The first production read-only vertical slice (accounts + dashboard) has passed repository, PostgreSQL parity, n8n cutover, and production HTTP runtime gates.

BE-DOM-001 as a whole is not yet closed because write-side finance invariants, idempotency, and transaction boundaries remain to be extracted from n8n/transport concerns.

## Goal

Extract financial/domain rules from transport/orchestration concerns so that the current n8n API layer can remain a replaceable adapter.

The target dependency direction is:

```text
UI
↓
API / Adapter
↓
Application / Read Models
↓
Domain
↓
Persistence
```

## Architectural rule

n8n is an MVP transport/orchestration layer only.

It may:

- authenticate/identify the caller;
- validate transport-level input shape;
- map HTTP/webhook payloads into application commands/queries;
- call PostgreSQL/domain entry points;
- map application results into API responses;
- perform non-domain orchestration around external services.

It must not own financial semantics.

Specifically, n8n must not be the canonical implementation of:

- account balance calculation;
- income/expense sign semantics;
- transfer semantics;
- currency conversion rules;
- base-currency valuation;
- transaction posting rules;
- duplicate financial posting protection;
- financial period aggregation;
- net worth calculation;
- category-level financial aggregation;
- transaction mutation invariants.

## Domain boundary

### Domain concepts

Initial finance domain contains at least:

- Account
- Transaction
- Transfer
- Money
- Currency
- ExchangeRate / ValuationRate
- Category
- Balance
- FinancialPeriod

These names describe domain responsibilities, not necessarily one-table-per-entity persistence.

### Domain invariants

The finance domain is responsible for enforcing rules such as:

1. Monetary amounts are never interpreted without a currency.
2. Account balances are derived from canonical financial postings, not independently edited aggregates.
3. A transfer is economically neutral at portfolio level, excluding explicit fees or FX gain/loss rules introduced later.
4. Income/expense semantics are domain semantics and must not depend on UI labels or n8n branch logic.
5. Currency conversion always records/uses an explicit valuation context; silent fallback to arbitrary rates is forbidden.
6. Repeating the same idempotent write must not create duplicate financial effects.
7. Read models may denormalize, but they do not become the source of truth for financial rules.

## Application layer

The application layer exposes use cases, not raw table operations.

Expected command/query shape:

```text
Commands
- CreateTransaction
- UpdateTransaction
- DeleteTransaction
- CreateTransfer

Queries
- GetDashboard
- GetAccounts
- GetTransactions
- GetAccountBalance
- GetPeriodSummary
```

Exact names may change during implementation; the separation of responsibilities must not.

## Persistence strategy for MVP

For BE-DOM-001, PostgreSQL remains the execution boundary for finance logic where practical.

Preferred extraction order:

1. Identify financial calculations currently embedded in n8n expressions / Function nodes / SQL fragments.
2. Move canonical calculations and invariants into versioned PostgreSQL functions/views/constraints or a backend-domain module when one already exists.
3. Keep n8n nodes as thin calls to those entry points.
4. Preserve current API response contracts unless a contract change is explicitly approved.
5. Add regression tests/verification queries for every extracted rule before deleting the old implementation.

This is an incremental strangler migration, not a rewrite.

## PostgreSQL rules

Database-side domain code introduced by this phase must be:

- versioned in the repository;
- deterministic for the same persisted state and explicit inputs;
- transaction-safe;
- schema-qualified;
- migration-safe;
- callable independently of n8n;
- covered by executable verification SQL or automated tests.

Avoid hidden dependence on session-local settings unless explicitly set by the entry point.

## Read models

Dashboard and MiniApp-facing aggregates belong to Application / Read Models.

Examples:

- current account balances;
- month income;
- month expense;
- month result;
- latest operations;
- category breakdowns;
- base-currency portfolio totals.

They may use SQL views/materialized views/functions, but their formulas must delegate to canonical domain semantics rather than duplicate them.

## n8n target state

A typical write workflow should converge toward:

```text
Webhook
→ auth / request validation
→ normalize transport payload
→ call one application/domain DB entry point
→ map result
→ HTTP response
```

A typical read workflow should converge toward:

```text
Webhook
→ auth / request validation
→ call read-model query
→ map result
→ HTTP response
```

No financial calculation should exist only inside an n8n node.

## Compatibility constraints

BE-DOM-001 must not require:

- replacing n8n;
- rewriting the MiniApp;
- changing public API routes merely for architectural purity;
- changing persisted financial meaning without a dedicated migration decision.

## Read-slice implementation

The first extracted vertical slice now uses versioned PostgreSQL entry points:

```text
moneytrack.finance_fx_convert_usd_bridge_v1(...)
moneytrack.finance_accounts_read_model_v1(...)
moneytrack.finance_dashboard_read_model_v1(...)
```

The production n8n nodes now resolve Telegram identity and delegate the financial read calculation to these entry points instead of embedding the formulas in workflow SQL.

### Runtime evidence — 2026-08-08

Representative production user:

```text
moneytrack.app_users.id = 1
accounts = 19
transactions = 113
```

Runtime gates passed:

- target `moneytrack` PostgreSQL schema and required tables confirmed;
- all three BE-DOM-001 PostgreSQL functions installed successfully;
- hard parity gate passed against real data for `user_id=1`, `as_of=2026-08-08`;
- candidate workflow differed only in `Get Dashboard` and `Get Accounts` SQL;
- n8n Public API update returned HTTP 200;
- active workflow version became `ea77110f-320e-40ab-ad03-dea749fc6596`;
- n8n restarted cleanly and registered all four MiniApp webhooks;
- authenticated production `/webhook/api/v1/dashboard` returned HTTP 200 with expected payload;
- authenticated production `/webhook/api/v1/accounts` returned HTTP 200 with expected payload;
- post-cutover n8n log scan found no finance/PostgreSQL runtime errors.

### Read-slice gate

```text
Repository forensic              PASS
PostgreSQL implementation        PASS
Real-data hard parity            PASS
Candidate isolation              PASS
n8n cutover                      PASS
Workflow activation              PASS
/dashboard production smoke      PASS
/accounts production smoke       PASS
Post-cutover error scan           PASS

READ SLICE                       PASS
```

## Acceptance criteria

BE-DOM-001 is complete only when:

- [x] existing finance-related n8n workflows have been inventoried for the selected read slice;
- [x] selected read-side financial logic has an identified canonical owner;
- [x] selected finance read logic has been extracted out of n8n into versioned domain/persistence code;
- [x] n8n calls extracted read entry points instead of reimplementing their formulas;
- [x] API behavior required by the current MiniApp remains compatible for `/dashboard` and `/accounts`;
- [ ] idempotency and transaction boundaries are explicit for financial writes;
- [x] regression verification covers balances and period aggregates;
- [x] the extracted read logic can be called without n8n;
- [x] no new financial business logic was added to n8n as part of the read extraction;
- [ ] transaction create/update/delete posting semantics have a canonical owner outside n8n;
- [ ] transfer write semantics have a canonical owner outside n8n;
- [ ] write-side regression/idempotency verification has passed against representative runtime data.

## Known compatibility debt (not a read-slice blocker)

The existing API exposes two different portfolio-value semantics:

- `/accounts.total_base` aggregates persisted `transactions.amount_base`;
- dashboard `net_worth` revalues currency balances through `exchange_rates_usd` at the dashboard valuation date.

The read extraction intentionally preserved this difference rather than changing financial meaning during an architectural migration. Any unification requires a separate finance-semantic decision and migration.

## Non-goals

This phase does not by itself introduce:

- a new standalone backend service;
- event sourcing;
- microservices;
- a generalized accounting ledger rewrite;
- investment/asset valuation architecture;
- removal of n8n.

Those decisions may follow later, but BE-DOM-001 must make them possible without another finance-engine rewrite.

## Migration safety rule

Do not delete an existing n8n implementation until the extracted equivalent is verified against representative existing data and API responses.

For every migrated rule use:

```text
observe existing behavior
→ encode canonical rule
→ compare old vs new
→ switch caller
→ verify
→ remove duplicate logic
```

## Next implementation step

Proceed to the write-side forensic/extraction slice.

Inventory the actual transaction mutation workflows and classify, at minimum:

- create transaction;
- update transaction;
- delete transaction;
- transfer/posting semantics;
- `amount_original` / `amount_base` derivation;
- account/currency validation;
- income/expense sign semantics;
- duplicate/idempotency protection;
- transaction boundaries and failure atomicity.

Then extract one write vertical slice behind a versioned PostgreSQL application/domain entry point, prove legacy parity and idempotency, and only then switch its n8n caller.