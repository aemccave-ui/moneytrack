# API-4 — Final API Integration Gate

## Status

CURRENT — final read-only integration gate

## Base

API-1 through API-3 are closed.

Production API baseline entering API-4:

- API inventory/contract frozen;
- live financial/read-model paths extracted behind backend boundaries;
- canonical success/error transport contract active on retained API endpoints;
- legacy `POST /moneytrack-test` removed;
- canonical Telegram InitData auth `api3b-v1` active on all 8 HTTP endpoints;
- `auth_date` freshness active;
- retained HTTP write surface reduced to ownership-scoped, state-idempotent transaction DELETE;
- global active direct business writers = 0.

## Goal

Perform one final read-only acceptance of the integrated API surface and establish the stable API baseline.

API-4 is not a refactoring phase. It must not reopen API-1/API-2/API-3 work unless fresh production evidence proves a blocking regression.

## Expected active HTTP surface

Exactly 8 endpoints:

| Method | Path | Disposition |
|---|---|---|
| GET | `/api/v1/dashboard` | retained |
| GET | `/api/v1/accounts` | retained |
| GET | `/api/v1/i18n` | retained read-only catalog adapter |
| GET | `/api/v1/me` | deprecated but active read-only legacy surface |
| DELETE | `/api/v1/transaction` | retained write |
| GET | `/api/v1/transaction-reference` | retained |
| GET | `/api/v1/transactions` | retained |
| GET | `/api/v1/accounts-explorer-summary` | retained |

`/moneytrack-test` must remain absent.

## Boundary expectations

Blocking backend-boundary paths:

- dashboard -> `moneytrack.finance_dashboard_read_model_v1`;
- accounts -> `moneytrack.finance_accounts_read_model_v1`;
- transactions -> `moneytrack.api_transactions_read_model_v1`;
- accounts-explorer-summary -> `moneytrack.api_accounts_explorer_summary_read_model_v1`;
- transaction-reference -> `moneytrack.api_transaction_reference_read_model_v1`;
- DELETE transaction -> `moneytrack.finance_delete_transaction_v1`.

`/api/v1/i18n` is an allowed read-only catalog adapter in the current stable baseline. `/api/v1/me` remains explicitly deprecated/read-only and is not a reason to reopen API-2 unless it becomes a blocking production dependency.

## Final gate

API-4 PASS requires fresh production evidence that:

1. all five API workflows are active and `versionId == activeVersionId`;
2. active API surface is exactly the expected 8 method/path pairs with unique ownership;
3. `/moneytrack-test` is absent;
4. all 8 auth paths contain canonical `api3b-v1` auth and no canonical auth node uses exception-style failures;
5. missing auth returns canonical `401 INIT_DATA_MISSING` on all 8 endpoints;
6. a freshly signed synthetic Telegram InitData request is accepted by auth and reaches the backend;
7. all six blocking backend boundary functions exist and are called by the expected workflow nodes;
8. retained mutation surface is exactly one DELETE endpoint;
9. no active n8n node directly mutates MoneyTrack business tables;
10. n8n health is PASS.

## Stable-baseline decision

If all gates pass, no production mutation is required. Evidence is recorded and merged, then the API program is CLOSED.

Any later API evolution becomes new roadmap work rather than a continuation of API-1..API-4.
