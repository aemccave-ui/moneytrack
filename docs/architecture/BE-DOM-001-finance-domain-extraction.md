# MoneyTrack — BE-DOM-001 — Finance Domain Extraction

## Status

IN PROGRESS

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

## Acceptance criteria

BE-DOM-001 is complete only when:

- [ ] existing finance-related n8n workflows have been inventoried;
- [ ] each piece of financial business logic has an identified canonical owner;
- [ ] selected finance logic has been extracted out of n8n into versioned domain/persistence code;
- [ ] n8n calls extracted entry points instead of reimplementing their formulas;
- [ ] API behavior required by the current MiniApp remains compatible;
- [ ] idempotency and transaction boundaries are explicit for financial writes;
- [ ] regression verification covers balances and period aggregates;
- [ ] the extracted logic can be called without n8n;
- [ ] no new financial business logic is added to n8n as part of this work.

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

Inventory the repository/runtime-owned n8n workflow definitions and SQL migrations, classify every finance calculation into:

- Domain invariant
- Application use case
- Read model
- Persistence-only concern
- Transport-only concern

Then extract one vertical slice first, preferably account balance + dashboard period summary, because it provides a read-only compatibility baseline before transaction-write mutations are moved.