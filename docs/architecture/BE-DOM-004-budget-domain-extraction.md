# BE-DOM-004 — Budget Domain Extraction

## Status

Production cutover and runtime validation completed successfully.

## Scope

BE-DOM-004 removes direct `moneytrack.budget_rules` mutations from active n8n workflow SQL while preserving the existing workflow topology and adapter output contracts.

Writer nodes migrated:

- `Insert Budget Rule`
- `Apply Budget Action`

Read-only budget consumers intentionally remain unchanged:

- `Command setting Budget`
- `Report Budget`

## Backend boundaries

### `moneytrack.budget_create_rule_v1`

Owns budget-rule creation semantics, including:

- resolved-input gating;
- user ownership validation;
- category ownership validation;
- currency/amount/recurrence/date validation;
- insertion into `budget_rules`;
- legacy adapter status contract.

### `moneytrack.budget_apply_action_v1`

Owns budget-rule mutation semantics for:

- `enable`;
- `disable`;
- `delete`.

The boundary scopes target resolution by `user_id`, so a foreign-user rule is exposed as `not_found` rather than mutated.

## Repository evidence

Implementation files:

- `db/domain/BE-DOM-004/010_budget_domain.sql`
- `db/domain/BE-DOM-004/011_verify_budget_domain.sql`
- `scripts/be-dom-004-transform-budget-cutover.py`
- `scripts/be-dom-004-verify-budget-cutover.py`

## Backend verifier

Rollback-safe verifier result:

- create semantics: PASS
- unresolved/invalid status semantics: PASS
- category ownership isolation: PASS
- action ownership isolation: PASS
- enable: PASS
- disable: PASS
- delete: PASS
- synthetic user leaks: 0
- synthetic category leaks: 0
- synthetic budget-rule leaks: 0

## Candidate gate

Main workflow baseline:

- workflow ID: `DER2Lc3dT2afyQhy`
- node count: `142`
- graph SHA-256: `59af0ac4fefedcd3d96d9eb483e2dc3ef99713e237dad47b45b8ee5619f7279f`

Changed nodes exactly:

- `Apply Budget Action`
- `Insert Budget Rule`

Candidate validation:

- structural isolation: PASS
- graph topology unchanged: PASS
- adapter output contracts: PASS
- read-only budget consumers unchanged: PASS
- direct budget writer bypass: 0
- candidate Main direct business mutations: 0

## Production cutover

Production state before cutover matched the captured BE-DOM-004 baseline.

PUT result:

- HTTP: `200`
- active workflow version: `6a112eb5-25cf-41fa-9a7a-e3535523ef8b`
- version counter: `4004`
- candidate node parity: PASS
- candidate graph parity: PASS

After n8n restart:

- health: PASS
- container running: true
- restart count: 0
- active/current version consistency: PASS
- fresh runtime export equals candidate: PASS

## Reversible runtime smoke

A production-backend smoke was executed inside an explicit database transaction and rolled back.

Fixture:

- user: `1`
- owned category: `54`
- currency: `EUR`
- temporary rule name: `BE_DOM_004_RUNTIME_SMOKE`

Lifecycle result:

1. create -> `added`
2. disable -> `disable`, persisted `is_active=false`
3. enable -> `enable`, persisted `is_active=true`
4. foreign-user delete attempt -> `not_found`, target preserved
5. owner delete -> `delete`, target removed
6. transaction -> `ROLLBACK`

The first smoke harness attempt contained a psql variable interpolation error inside a dollar-quoted `DO` block. The database transaction was aborted and connection close rolled it back; leak proof returned zero rows. The corrected smoke then completed successfully.

Final runtime smoke leak count:

- `BE_DOM_004_RUNTIME_SMOKE`: `0`

## Closed-domain bypass state

After production cutover and runtime validation:

- finance bypass: `0`
- receipt/catalog bypass: `0`
- user lifecycle bypass: `0`
- budget bypass: `0`

## Remaining active direct writer

Exactly one active direct business-table writer remains globally:

- workflow `eOidxxekEVyAjeep` — `MoneyTrack Update Exchange Rates`
- node `Upsert exchange rates`
- operation `INSERT INTO moneytrack.exchange_rates_usd`

This is the complete remaining scope for BE-DOM-005 — FX Rate Ingestion.

## Gate

BE-DOM-004 backend, candidate, production, runtime, ownership, rollback, and zero-bypass gates are PASS.
