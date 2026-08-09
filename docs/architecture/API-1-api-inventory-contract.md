# API-1 — API Inventory & Contract Baseline

## Status

COMPLETE

## Goal

Establish one canonical inventory of MoneyTrack HTTP API contracts before any request/response normalization or auth hardening.

API-1 is discovery and documentation only. It does not change endpoint behavior, n8n workflow topology, PostgreSQL domain semantics, frontend behavior, or production data.

## Architecture invariant

```text
MiniApp / external HTTP consumer
        -> stable HTTP contract
        -> thin n8n adapter
        -> backend/read-model boundary
        -> PostgreSQL
```

Telegram command workflows remain a separate channel adapter and are not classified as REST API endpoints unless they expose an active HTTP Webhook node.

## Runtime baseline

Inventory executed against production n8n after completion of BE-DOM-001..005 and final hardening.

Results:

- active HTTP webhook endpoints: **9**;
- active workflows owning those endpoints: **6**;
- duplicate active `(method,path)` ownership: **0**;
- direct active business-table writer nodes: **0**;
- known API workflow anchors present and active: **5/5**;
- all known API workflow `versionId == activeVersionId`: **PASS**;
- n8n health: **PASS**.

The working-tree inventory reported one unrelated untracked `scripts/__pycache__/` directory. It is not part of the API-1 branch diff and is not API contract drift.

## Canonical active endpoint inventory

| Method | Path | Workflow | Data path | Repository consumer | API-2 disposition |
|---|---|---|---|---|---|
| GET | `/api/v1/dashboard` | `7TJ2xQTxLsTydXZc` — MoneyTrack MiniApp API | `finance_dashboard_read_model_v1` | `App.jsx -> getDashboard()` | `KEEP_AS_IS` |
| GET | `/api/v1/accounts` | `7TJ2xQTxLsTydXZc` — MoneyTrack MiniApp API | `finance_accounts_read_model_v1` | `App.jsx`, `RecentOperations.jsx -> getAccounts()` | `KEEP_AS_IS` |
| GET | `/api/v1/i18n` | `7TJ2xQTxLsTydXZc` — MoneyTrack MiniApp API | direct read SQL | no current MiniApp helper consumer found | `DEPRECATE_OR_MERGE` |
| GET | `/api/v1/me` | `7TJ2xQTxLsTydXZc` — MoneyTrack MiniApp API | direct read SQL | no current MiniApp helper consumer found | `DEPRECATE_OR_MERGE` |
| DELETE | `/api/v1/transaction` | `MTxDel7Qp2Vn9Kc4` — MiniApp Delete Transaction | `finance_delete_transaction_v1` | `RecentOperations.jsx -> deleteTransaction()` | `KEEP_AS_IS` |
| GET | `/api/v1/transaction-reference` | `MTxRef4Qp8Lm2Xs6` — MiniApp Transaction Reference | direct read SQL | `RecentOperations.jsx -> getTransactionReference()` | `MOVE_READ_MODEL` |
| GET | `/api/v1/transactions` | `UX022TxApi202608` — Transactions API | complex direct read SQL | `AccountsExplorer.jsx -> getTransactions()` | `MOVE_READ_MODEL` |
| GET | `/api/v1/accounts-explorer-summary` | `UX022Summary202608` — Accounts Explorer Summary API | complex direct read SQL | `AccountsExplorer.jsx -> getAccountsExplorerSummary()` | `MOVE_READ_MODEL` |
| POST | `/moneytrack-test` | `DER2Lc3dT2afyQhy` — MoneyTrack | mixed 142-node Telegram workflow | no MiniApp consumer found | `DEPRECATE_OR_MERGE` |

The `moneytrack-test` webhook is intentionally separated from the stable `/api/v1/*` surface. Its presence causes the whole large Telegram orchestration workflow to appear in API node-mix reports; this does **not** mean its 49 Postgres nodes and 58 Code nodes form one REST endpoint implementation. API-2 should treat this test ingress as a retirement/isolation item rather than normalize the entire Telegram workflow as an HTTP API.

## Data-path classification

### Already behind backend/read-model boundaries

- `/api/v1/dashboard` -> `finance_dashboard_read_model_v1`;
- `/api/v1/accounts` -> `finance_accounts_read_model_v1`;
- `DELETE /api/v1/transaction` -> `finance_delete_transaction_v1`.

These endpoints are the current target shape: n8n validates/maps the request and delegates domain/read semantics to PostgreSQL boundaries.

### Direct read SQL remaining in HTTP adapters

- `/api/v1/i18n`;
- `/api/v1/me`;
- `/api/v1/transaction-reference`;
- `/api/v1/transactions`;
- `/api/v1/accounts-explorer-summary`.

Direct read SQL is not a BE-DOM regression because API-1 reconfirmed direct **writers = 0**. It is API-2 prioritization input.

The highest-value read-model extractions are `/api/v1/transactions` and `/api/v1/accounts-explorer-summary`: both contain substantial account ownership, hierarchy, FX conversion, period aggregation, and response-shaping semantics in n8n SQL. `/api/v1/transaction-reference` is smaller but live and reused by the transaction editor.

`/api/v1/me` and `/api/v1/i18n` currently have no consumer in the relevant MiniApp source refs, so API-2 should first confirm whether they are contractual/future surfaces before investing in new read models.

## Consumer baseline

The canonical backend `main` currently contains workflow sources but no active MiniApp `/api/v1/*` calls. Relevant frontend consumers live on the current UI refs:

- `fix/restore-modern-preview-ui-20260806`;
- `agent/ux-022-accounts-explorer`.

Confirmed live caller mapping from source:

- `getDashboard()` -> `/api/v1/dashboard`;
- `getAccounts()` -> `/api/v1/accounts`;
- `getTransactionReference()` -> `/api/v1/transaction-reference`;
- `deleteTransaction()` -> `DELETE /api/v1/transaction`;
- `getTransactions()` -> `/api/v1/transactions`;
- `getAccountsExplorerSummary()` -> `/api/v1/accounts-explorer-summary`.

`App.jsx` loads Dashboard and Accounts together. `AccountsExplorer.jsx` uses Transactions and Explorer Summary. `RecentOperations.jsx` uses Transaction Reference, Accounts and Delete Transaction.

This source split is a delivery/canonical-frontend concern for API-4 integration, not an API-1 blocker.

## Contract normalization findings

The current frontend helper deliberately tolerates multiple response shapes:

```text
payload.data ?? payload
```

and separately checks:

```text
payload.error
```

Delete has its own error-response parsing path.

This is evidence that API-2 must freeze one response/error envelope for retained endpoints rather than keep frontend compatibility logic as the long-term contract.

Recommended API-2 envelope target:

```json
{
  "ok": true,
  "data": {}
}
```

and errors:

```json
{
  "ok": false,
  "error": {
    "code": "STABLE_CODE",
    "message": "optional human-readable text"
  }
}
```

Exact HTTP status mapping is an API-2 design decision; API-1 only records the inconsistency.

## Authentication baseline

All active n8n Webhook nodes report webhook-level `authentication = none`.

That does **not** mean the MiniApp endpoints are currently unauthenticated. The dedicated MiniApp workflows verify Telegram MiniApp InitData inside Code nodes using the Telegram HMAC pattern and derive `telegram_user_id` from the verified user payload. UX-022 Transactions and Explorer Summary perform the same validation inline in their request-validation Code nodes.

However, the verification logic is duplicated across workflows, and the current MiniApp verifier has HMAC validation but no `auth_date` freshness/expiry check.

Therefore API-3 must treat authentication as a cross-cutting contract:

1. one canonical InitData verification implementation/pattern;
2. HMAC verification;
3. required `auth_date` validation and maximum age;
4. user identity derived only from verified InitData;
5. ownership checks kept inside backend/read-model boundaries where possible;
6. stable 401/403 semantics;
7. rate limiting and suspicious-request logging as production hardening.

## API-2 priorities

### P0 — isolate/remove non-contract test ingress

- `POST /moneytrack-test` -> `DEPRECATE_OR_MERGE`.

It is not part of `/api/v1/*`, has no MiniApp consumer in the inspected refs, and exposes the large Telegram orchestration workflow as HTTP ingress.

### P1 — move live complex reads behind read models

1. `GET /api/v1/transactions`;
2. `GET /api/v1/accounts-explorer-summary`;
3. `GET /api/v1/transaction-reference`.

### P2 — normalize retained HTTP contracts

- `/api/v1/dashboard`;
- `/api/v1/accounts`;
- `DELETE /api/v1/transaction`;
- new read-model endpoints from P1.

Normalize success/error envelope, validation failures, HTTP status semantics, field naming and empty-result behavior without changing product meaning.

### P3 — resolve unused/legacy surfaces

- `/api/v1/me`;
- `/api/v1/i18n`.

Either document a real consumer/future contract and retain them, or deprecate/merge them. Do not build new backend boundaries for unused endpoints first.

## API-1 gate result

```text
API-1 SCOPE FREEZE                 PASS
ACTIVE HTTP INVENTORY             PASS — 9 endpoints
KNOWN WORKFLOW VERSION CONSISTENCY PASS — 5/5
ENDPOINT COLLISIONS               PASS — 0
CONSUMER MAPPING                  PASS
DATA-PATH CLASSIFICATION          PASS
DIRECT BUSINESS WRITERS           PASS — 0
N8N HEALTH                        PASS
API-2 DISPOSITIONS                PASS — assigned

API-1 — COMPLETE
```

## Out of scope completed as designed

API-1 did not:

- rename endpoints;
- change request or response payloads;
- add auth checks;
- migrate direct read SQL;
- change MiniApp code;
- change Telegram behavior;
- execute write-path smoke tests;
- reopen BE-DOM-001..005.

## Next phases

- **API-2 — Request/Response Contract Normalization + retained read-model extraction.**
- **API-3 — Auth / Ownership / Idempotency hardening.**
- **API-4 — Integration Gate and stable API baseline.**
