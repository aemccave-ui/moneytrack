# API-2B — Contract Normalization

## Status

CURRENT

## Base

API-2A is closed and merged. The retained live read paths are already behind backend/read-model boundaries.

API-2B changes transport contracts only. It must not move business semantics back into n8n and must not change backend read/write semantics.

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

## Target success envelope

Every retained endpoint must return successful JSON as:

```json
{
  "ok": true,
  "data": {}
}
```

`data` may be an object, array, scalar or `null` only where the endpoint contract explicitly permits it.

## Target error envelope

Every retained endpoint must return errors as:

```json
{
  "ok": false,
  "error": {
    "code": "STABLE_CODE",
    "message": "optional human-readable text"
  }
}
```

The stable machine-readable contract is `error.code`. Human-readable `message` is optional and must not be required by clients for branching.

## HTTP status policy

API-2B normalizes transport status without changing product meaning:

- `200` — successful read/delete response;
- `400` — malformed or missing request parameters;
- `401` — missing/invalid current authentication material as detected by existing auth logic;
- `404` — requested user/account/transaction/resource not found or not owned where existing semantics intentionally expose not-found;
- `500` — missing server configuration or unexpected adapter/backend failure.

API-2B does not introduce `403`, replay expiry, rate limits or new authorization distinctions; those belong to API-3 unless an existing endpoint already has a frozen behavior that must be preserved.

## Field compatibility rule

API-2B does not rename business fields inside `data`.

Examples:

- dashboard summary fields remain unchanged;
- accounts/default-account fields remain unchanged;
- transactions and summary fields remain unchanged;
- transaction-reference `currencies` and `categories` remain unchanged.

Only the outer transport envelope and error representation are normalized in API-2B.

## Empty-result policy

- collection reads return successful empty collections inside `data`, not an empty HTTP body;
- successful delete returns a JSON success envelope, not an empty body;
- not-found remains an error response where the existing endpoint treats it as not-found.

## Frontend compatibility

Current MiniApp helper tolerates both wrapped and unwrapped responses using `payload.data ?? payload`, and delete has separate parsing. API-2B must update the frontend adapter so it consumes one canonical envelope while keeping UI/business behavior unchanged.

No component-level UX redesign belongs to API-2B.

## Cutover strategy

1. read-only production preflight captures exact active response/auth/validation nodes;
2. freeze endpoint-by-endpoint current status/error mapping;
3. build candidate workflow JSON from fresh active exports;
4. change only adapter/response-formatting fields required for canonical envelope/status;
5. update MiniApp `api.js` helper to one parser;
6. structural verification proves backend/data-path nodes and graph semantics are unchanged;
7. production cutover retained endpoints;
8. contract smoke + n8n health + global zero-writer invariant;
9. merge evidence.

## Gates

### Preflight gate

- all 5 workflow IDs active/version-consistent;
- 6 retained `(method,path)` endpoints present exactly once;
- exact current response nodes/status mappings captured;
- backend/read-model target nodes remain unchanged from API-2A;
- global direct business writers remain `0`.

### Candidate gate

- no endpoint method/path changes;
- no backend query/function changes;
- no auth algorithm changes;
- response envelope/status normalization only;
- frontend helper compiles/lints;
- structural verifier PASS.

### Production gate

- canonical success/error envelope on all retained endpoints;
- expected status codes preserved/normalized;
- active versions consistent;
- n8n health PASS;
- global direct business writers remain `0`.

## Next

After API-2B:

- API-2C — unused/legacy surface decision;
- API-3 — centralized Telegram InitData/auth/ownership/idempotency hardening;
- API-4 — final API integration gate.
