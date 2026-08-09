# API-2A — Live Read Models

## Status

CLOSED / ACCEPTED FOR MERGE

## Base

API-1 closed/merged before this phase. API-2A is limited to the three confirmed live MiniApp read paths that still contained substantial direct business-table SQL in active n8n workflows.

## Scope

| Endpoint | Workflow | Target Postgres node | Backend read model |
|---|---|---|---|
| `GET /api/v1/transactions` | `UX022TxApi202608` | `Get Account Transactions` | `moneytrack.api_transactions_read_model_v1` |
| `GET /api/v1/accounts-explorer-summary` | `UX022Summary202608` | `Get Explorer Summary` | `moneytrack.api_accounts_explorer_summary_read_model_v1` |
| `GET /api/v1/transaction-reference` | `MTxRef4Qp8Lm2Xs6` | `Get Transaction Reference` | `moneytrack.api_transaction_reference_read_model_v1` |

## Frozen compatibility rules

API-2A preserves existing endpoint behavior.

### Transactions

Preserved:

- verified Telegram identity as the caller input;
- selected-account ownership restriction;
- optional descendant-account recursion;
- inclusive requested date range via `< date_to + 1 day`;
- historical FX conversion using latest rate on/before transaction date;
- legacy USD-bridge conversion orientation through `finance_fx_convert_usd_bridge_v1`;
- leaf-account summary in the selected account currency;
- multi-account summary in user base currency;
- transaction JSON fields/order;
- `USER_NOT_FOUND` / `ACCOUNT_NOT_FOUND` behavior remains response-formatter behavior.

### Accounts Explorer Summary

Preserved:

- verified Telegram identity as caller input;
- active leaf-account exclusion behavior;
- automatic ancestor inclusion;
- transaction + transfer movement balance semantics;
- current/as-of-date FX for balances;
- transaction-date FX for period income/expense;
- existing period/result/missing-rate fields.

### Transaction Reference

Preserved:

- active currencies;
- currency usage counts from the current user’s transactions;
- used currencies sorted ahead of unused currencies, then code ascending;
- active global (`user_id=0`) plus user-owned categories;
- user-language translation with English fallback and code fallback;
- category parent/sort compatibility fields and ordering.

## What did not change in API-2A

- HTTP method/path;
- Webhook nodes;
- Telegram InitData HMAC verification Code nodes;
- request validation Code nodes;
- response formatter Code nodes;
- HTTP response envelope/status behavior;
- frontend code;
- graph topology;
- business writes;
- `/api/v1/dashboard`, `/api/v1/accounts`, transaction delete;
- `/api/v1/me`, `/api/v1/i18n`, `POST /moneytrack-test`.

Auth freshness/expiry and duplicated verifier code remain explicitly assigned to API-3.

## Backend implementation

Introduced compatibility read models:

- `moneytrack.api_transactions_read_model_v1(bigint, text, date, date, boolean)`
- `moneytrack.api_accounts_explorer_summary_read_model_v1(bigint, bigint[], date, date, date)`
- `moneytrack.api_transaction_reference_read_model_v1(bigint)`

The models are compatibility-first. Existing request validation and response formatting stay in n8n in API-2A; only the substantial direct-read SQL moved behind PostgreSQL application/read-model boundaries.

## Backend verification

Migration install: PASS.

Rollback-safe verifier: PASS.

Verified:

- exact function signatures;
- representative existing-user read contracts;
- ownership isolation;
- unknown-user behavior;
- verifier rollback.

## Candidate verification

Fresh active production baselines before cutover:

- `UX022TxApi202608`: active, version counter `5`, active/version IDs equal;
- `UX022Summary202608`: active, version counter `4`, active/version IDs equal;
- `MTxRef4Qp8Lm2Xs6`: active, version counter `2`, active/version IDs equal.

For every candidate:

- graph topology unchanged: PASS;
- node count unchanged: PASS;
- exactly one target node changed: PASS;
- target change query-only: PASS;
- expected backend read-model call present: PASS;
- direct business-table SQL removed from target node: PASS.

## Production cutover

The first cutover attempt was rejected before any workflow update with HTTP `400` because a full GET-derived `settings` object contained Public API-unsupported properties. This was a cutover-harness schema issue, not a product failure. No workflow was changed in that attempt.

The cutover harness was corrected to send an API-safe settings allowlist containing only `executionOrder`.

Final cutover result:

### Transactions

- workflow: `UX022TxApi202608`
- PUT: `200`
- version counter: `5 -> 6`
- new version ID: `b801d1da-5e69-484f-a839-f625d68ce1c8`
- `versionId == activeVersionId`: PASS
- target: `Get Account Transactions`
- backend boundary: `api_transactions_read_model_v1`
- production cutover: PASS

### Accounts Explorer Summary

- workflow: `UX022Summary202608`
- PUT: `200`
- version counter: `4 -> 5`
- new version ID: `5cf819be-f1f0-40b3-8c18-ac553cf0cd3b`
- `versionId == activeVersionId`: PASS
- target: `Get Explorer Summary`
- backend boundary: `api_accounts_explorer_summary_read_model_v1`
- production cutover: PASS

### Transaction Reference

- workflow: `MTxRef4Qp8Lm2Xs6`
- PUT: `200`
- version counter: `2 -> 3`
- new version ID: `d8c53cd8-716a-4cf8-a237-2ce90af62c94`
- `versionId == activeVersionId`: PASS
- target: `Get Transaction Reference`
- backend boundary: `api_transaction_reference_read_model_v1`
- production cutover: PASS

## Post-cutover isolation

For all three production workflows:

- graph parity: PASS;
- changed node exactly the expected Postgres node: PASS;
- query-only change: PASS;
- backend call parity: PASS;
- production nodes equal candidate nodes: PASS;
- production connections equal candidate connections: PASS.

Target data-path inventory classifies all three target nodes as `BACKEND_BOUNDARY`.

No independent endpoint call with a captured live Telegram InitData token was forced as a blocking test. Contract compatibility is instead supported by the rollback-safe backend verifier plus exact preservation of request-validation, auth, response-formatting nodes and graph topology. A user-facing endpoint smoke can remain operational evidence, not a blocker for this structural extraction.

## Global architecture invariant

After production cutover:

- global active direct business mutation inventory: `(0 rows)`;
- `global_direct_business_writer_nodes = 0`;
- n8n health: PASS (`{"status":"ok"}`).

## Acceptance

API-2A gate:

- backend migration: PASS;
- rollback-safe backend verifier: PASS;
- candidate isolation: PASS;
- all three production PUTs: PASS;
- active/version consistency: PASS;
- exact production/candidate parity: PASS;
- target read paths behind backend boundaries: PASS;
- global direct business writers: `0`;
- n8n health: PASS.

API-2A is complete for the architectural objective.

## Next

- API-2B — request/response contract normalization;
- API-2C — `/me`, `/i18n`, `/moneytrack-test` surface decision;
- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
