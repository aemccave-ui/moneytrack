# MoneyTrack — BE-DOM-003 — User Lifecycle / Preferences Domain Extraction

## Status

**RUNTIME GATE PASS / READY TO MERGE**

## Goal

Move user bootstrap, lifecycle preference mutations, default-account selection, and delete-request issuance out of active n8n SQL writers into versioned PostgreSQL backend boundaries while preserving existing workflow topology and adapter contracts.

## Canonical backend boundaries

- `moneytrack.user_bootstrap_v1(bigint,text,text,text)`
- `moneytrack.user_set_language_v1(bigint,text)`
- `moneytrack.user_set_currency_v1(bigint,text,text)`
- `moneytrack.user_set_default_account_v1(bigint,text,text)`
- `moneytrack.user_create_delete_request_v1(bigint)`

Existing destructive erasure remains owned by the BE-DOM-001 boundary:

- `moneytrack.user_delete_me_v1(bigint,text)`

Category bootstrap remains delegated to the BE-DOM-002 boundary:

- `moneytrack.catalog_ensure_user_categories_v1(bigint)`

## n8n cutover

Workflow `DER2Lc3dT2afyQhy` (`MoneyTrack`) now delegates:

- `Command Start` -> `user_bootstrap_v1`
- `Get or Create User` -> `user_bootstrap_v1`
- `Create Delete Me Request` -> `user_create_delete_request_v1`
- `Set default account` -> `user_set_default_account_v1`
- `Update Language` -> `user_set_language_v1`
- `Update User Currency` -> `user_set_currency_v1`

The two previously independent bootstrap implementations are therefore unified behind one canonical backend boundary.

## Backend verification

Rollback-safe verifier passed for:

- bootstrap creation;
- bootstrap idempotency;
- existing user-state preservation;
- language preference validation/update;
- base/report currency preference validation/update;
- default-account ownership/currency matching;
- delete-request issuance and replacement;
- compatibility with `user_delete_me_v1`;
- rollback cleanup.

Synthetic leak checks returned zero users and zero private test accounts.

## Production cutover state

Active MoneyTrack workflow version:

`e8996c77-fa32-4db8-99d2-de6f400de2fe`

Version counter:

`4003`

The production drift check discovered that the exact candidate had already been applied. Independent classification proved:

- all six changed SQL nodes were byte-equivalent to candidate SQL;
- full node array equals the verified candidate;
- workflow connections equal the verified candidate;
- changed-node set is exactly the intended six nodes;
- active `versionId == activeVersionId`;
- direct lifecycle writers are zero.

No second PUT was performed.

## Runtime evidence — 2026-08-09

n8n restart and health gate passed.

Fresh runtime export contained all five BE-DOM-003 backend calls.

A production `/start` smoke was executed against user `1`:

- execution `133050`;
- workflow `DER2Lc3dT2afyQhy`;
- status `success`.

Pre/post bootstrap object counts were identical:

- accounts: 19;
- categories: 45;
- owned workspaces: 1;
- per-currency default accounts: 4;
- user settings rows: 1;
- workspace memberships: 1.

Pre/post settings remained identical:

`user_id=1, language=ru, base=EUR, report=EUR, default_expense_account_id=6, default_income_account_id=6, current_workspace_id=4`

Pre/post per-currency defaults remained identical:

- EUR -> account 6 (`freedom.eur`)
- KZT -> account 9 (`freedom.kzt`)
- RUB -> account 17 (`cash.rub`)
- USD -> account 16 (`cash.usd`)

Idempotency gates passed:

- `bootstrap_object_counts_stable=PASS`
- `bootstrap_settings_stable=PASS`
- `bootstrap_default_accounts_stable=PASS`

Duplicate/ownership invariant queries returned zero rows for:

- duplicate `(user_id, code)` accounts;
- duplicate active personal workspaces;
- duplicate workspace memberships;
- duplicate `(user_id, currency_code)` defaults.

## Final bypass gates

Active workflow scans after runtime smoke:

- finance bypass: `0`
- receipt/catalog bypass: `0`
- user lifecycle bypass: `0`

## Remaining active n8n business writers

Only two remaining domains are present:

### Budget

Workflow `MoneyTrack`:

- `Apply Budget Action` -> `budget_rules` update/delete
- `Insert Budget Rule` -> `budget_rules` insert

### FX ingestion

Workflow `MoneyTrack Update Exchange Rates`:

- `Upsert exchange rates` -> `exchange_rates_usd` insert/upsert

This leaves BE-DOM-004 Budget and BE-DOM-005 FX ingestion as the final writer slices before the global zero-writer architecture gate.

## Gate

```text
BE-DOM-003
BACKEND GATE:       PASS
CANDIDATE GATE:     PASS
PRODUCTION PARITY:  PASS
RUNTIME GATE:       PASS
LIFECYCLE BYPASS:   0
STATUS:             READY TO MERGE
```
