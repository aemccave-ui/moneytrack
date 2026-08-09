# API-2A — Live Read Models

## Status

CURRENT

## Base

API-1 closed/merged before this phase. API-2A is limited to the three confirmed live MiniApp read paths that still contain substantial direct business-table SQL in active n8n workflows.

## Scope

| Endpoint | Workflow | Target Postgres node | Backend read model |
|---|---|---|---|
| `GET /api/v1/transactions` | `UX022TxApi202608` | `Get Account Transactions` | `moneytrack.api_transactions_read_model_v1` |
| `GET /api/v1/accounts-explorer-summary` | `UX022Summary202608` | `Get Explorer Summary` | `moneytrack.api_accounts_explorer_summary_read_model_v1` |
| `GET /api/v1/transaction-reference` | `MTxRef4Qp8Lm2Xs6` | `Get Transaction Reference` | `moneytrack.api_transaction_reference_read_model_v1` |

## Frozen compatibility rules

API-2A must preserve existing endpoint behavior.

### Transactions

Preserve:

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

Preserve:

- verified Telegram identity as caller input;
- active leaf-account exclusion behavior;
- automatic ancestor inclusion;
- transaction + transfer movement balance semantics;
- current/as-of-date FX for balances;
- transaction-date FX for period income/expense;
- existing period/result/missing-rate fields.

### Transaction Reference

Preserve:

- active currencies;
- currency usage counts from the current user’s transactions;
- used currencies sorted ahead of unused currencies, then code ascending;
- active global (`user_id=0`) plus user-owned categories;
- user-language translation with English fallback and code fallback;
- category parent/sort compatibility fields and ordering.

## What does not change in API-2A

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

## Cutover invariant

For each of the three workflows, the production cutover may change exactly one field:

```text
<TARGET POSTGRES NODE>.parameters.query
```

All other node properties and all connections must remain identical.

After cutover, the target query must call its `moneytrack.api_*_read_model_v1` function and must not directly read MoneyTrack business tables.

## Gates

### Backend gate

- migration installs;
- all three signatures exist;
- rollback-safe verifier PASS;
- existing-user representative semantics PASS;
- unknown-user ownership isolation PASS.

### Candidate gate

Using fresh active runtime exports:

- workflow IDs match;
- active version is current before mutation;
- node count unchanged;
- graph unchanged;
- exactly one target node changed per workflow;
- target change is query-only;
- target query calls expected read model;
- target direct business-table reads = 0;
- direct business-table writers remain 0.

### Production gate

- exact candidate payload deployed to each of the three workflow IDs;
- version/active-version consistency PASS after publish/restart as required by current n8n runtime;
- target query/backend-boundary parity PASS;
- API endpoint smoke retains response contract;
- global direct business writer count remains 0;
- n8n health PASS.

## Next

After API-2A closes:

- API-2B — request/response contract normalization;
- API-2C — `/me`, `/i18n`, `/moneytrack-test` surface decision;
- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
