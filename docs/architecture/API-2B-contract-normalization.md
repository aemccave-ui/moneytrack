# API-2B — Contract Normalization

## Status

COMPLETE

## Base

API-2A is closed and merged. The retained live read paths are already behind backend/read-model boundaries.

API-2B changes transport contracts only. It does not move business semantics back into n8n and does not change backend read/write semantics.

## Retained live endpoint scope

| Method | Path | Workflow |
|---|---|---|
| GET | `/api/v1/dashboard` | `7TJ2xQTxLsTydXZc` |
| GET | `/api/v1/accounts` | `7TJ2xQTxLsTydXZc` |
| DELETE | `/api/v1/transaction` | `MTxDel7Qp2Vn9Kc4` |
| GET | `/api/v1/transaction-reference` | `MTxRef4Qp8Lm2Xs6` |
| GET | `/api/v1/transactions` | `UX022TxApi202608` |
| GET | `/api/v1/accounts-explorer-summary` | `UX022Summary202608` |

Out of API-2B scope:

- `/api/v1/me`;
- `/api/v1/i18n`;
- `POST /moneytrack-test`;
- Telegram InitData verification algorithm/freshness;
- rate limiting;
- ownership/domain semantics;
- endpoint path renaming;
- backend read/write functions.

Unused/legacy surface decisions belong to API-2C. Auth freshness and centralized verification belong to API-3.

## Canonical success envelope

Retained endpoints now return successful JSON as:

```json
{
  "ok": true,
  "data": {}
}
```

Business fields inside `data` are unchanged.

## Canonical handled-error envelope

Handled adapter/business errors now use:

```json
{
  "ok": false,
  "error": {
    "code": "STABLE_CODE"
  }
}
```

The stable machine-readable contract is `error.code`.

Exceptions raised inside the existing Telegram InitData verifier before a Respond node are intentionally not normalized in API-2B. Their control-flow, freshness checks, and common 401/403 behavior are API-3 scope.

## HTTP status policy

API-2B normalizes handled transport status without changing product meaning:

- `200` — successful read/delete response;
- `400` — malformed or missing request parameters where existing validators already produce handled validation results;
- `401` — handled missing/invalid authentication material where the existing flow already produces a handled result;
- `404` — user/account/transaction/resource not found where existing semantics intentionally expose not-found;
- `500` — fallback for handled unexpected adapter errors.

API-2B does not introduce replay expiry, centralized auth handling, rate limits, or new authorization distinctions.

## Field compatibility rule

API-2B does not rename business fields inside `data`.

Preserved examples:

- dashboard period/summary/balance/latest-operation fields;
- accounts/default-account/tree fields;
- transaction list and transaction summary fields;
- accounts explorer summary fields;
- transaction-reference `currencies` and `categories`;
- delete transaction result fields.

## Preflight result

Production preflight passed:

- all 5 workflow IDs active;
- all 5 `versionId == activeVersionId`;
- all 6 retained `(method,path)` endpoints owned exactly once;
- backend/read-model target nodes preserved from API-2A;
- global active direct business writers: `0`;
- n8n health: PASS.

## Candidate isolation result

Candidate transformation changed only the frozen adapter fields.

Changed nodes:

- MiniApp API: `Format Dashboard Response`, `Respond to Webhook`, `Format Accounts Response`, `Respond to Webhook2`;
- Delete: `Format Delete Response`, `Respond Delete`;
- Transaction Reference: `Format Transaction Reference`, `Respond Reference`;
- Transactions: `Respond Transactions`, `Respond Transactions Error`;
- Explorer Summary: `Respond Explorer Summary`, `Respond Explorer Summary Error`.

Structural verifier proved for every workflow:

- connections unchanged;
- Webhook method/path unchanged;
- Postgres/backend nodes unchanged;
- Telegram InitData verification nodes unchanged;
- Transactions/Explorer request validation nodes unchanged;
- only permitted formatter/respond fields changed;
- canonical contract markers present.

Candidate structural gate: PASS.

## Production cutover

All five workflow updates returned HTTP 200.

| Workflow | Version before | Version after | Result |
|---|---:|---:|---|
| `7TJ2xQTxLsTydXZc` — MoneyTrack MiniApp API | 478 | 479 | PASS |
| `MTxDel7Qp2Vn9Kc4` — Delete Transaction | 2 | 3 | PASS |
| `MTxRef4Qp8Lm2Xs6` — Transaction Reference | 3 | 4 | PASS |
| `UX022TxApi202608` — Transactions API | 6 | 7 | PASS |
| `UX022Summary202608` — Explorer Summary API | 5 | 6 | PASS |

For all five after cutover:

- active: true;
- `versionId == activeVersionId`: PASS;
- version counter incremented exactly by one;
- post-cutover structural verifier: PASS;
- production nodes/connections equal candidate: PASS.

## Canonical response inventory after cutover

MiniApp dashboard/accounts:

- formatter success contains `ok: true`;
- formatter handled error contains `error.code`;
- Respond node returns full `$json`;
- response code is `$json.http_status || 200`.

Delete and Transaction Reference:

- formatter success contains `ok: true`;
- handled not-found uses canonical `error.code` + `http_status=404`;
- Respond node returns full `$json` with dynamic response code.

Transactions and Explorer Summary:

- existing upstream `ok/http_status/data/error` result was retained;
- success Respond now returns full `$json` with HTTP 200;
- error Respond now returns `{ok:false,error:{code}}` and uses `$json.http_status || 500`.

## Frontend compatibility

The current MiniApp helper already reads success payloads through `payload.data ?? payload` and treats HTTP non-2xx as an error before requiring the legacy scalar `payload.error` shape. Therefore the server-side canonical envelope cutover did not require a synchronous frontend deployment.

A later frontend integration/canonicalization step may simplify the helper to require the canonical envelope only. That is delivery cleanup, not a blocker for the API-2B production contract gate.

## Architecture invariants after cutover

- global active direct business mutation inventory: `(0 rows)`;
- `global_direct_business_writer_nodes = 0`;
- n8n health: PASS;
- backend/read-model queries unchanged;
- auth algorithm unchanged;
- workflow topology unchanged.

## Acceptance

```text
API-2B PREFLIGHT                  PASS
CANDIDATE ISOLATION              PASS
PRODUCTION PUT                   PASS — 5/5
ACTIVE VERSION CONSISTENCY       PASS — 5/5
CANONICAL SUCCESS ENVELOPE       PASS
CANONICAL HANDLED ERROR ENVELOPE PASS
BACKEND/AUTH/GRAPH PARITY        PASS
DIRECT BUSINESS WRITERS          PASS — 0
N8N HEALTH                       PASS

API-2B — COMPLETE
```

## Next

- API-2C — unused/legacy surface decision for `/api/v1/me`, `/api/v1/i18n`, `/moneytrack-test`;
- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
