# API-3 — Auth Hardening

## Status

API-3A — COMPLETE

API-3B — COMPLETE / PRODUCTION CUTOVER PASS

API-3C — NEXT

## Base

API-1, API-2A, API-2B and API-2C are closed and merged. `POST /moneytrack-test` has been removed. The active HTTP surface consists of seven retained MiniApp API endpoints plus deprecated-but-active `/api/v1/me`.

## Goal

Establish one canonical Telegram MiniApp authentication contract for every active MoneyTrack HTTP endpoint without moving business semantics back into n8n.

Target architecture:

```text
MiniApp request
  -> canonical Telegram InitData verification
  -> verified telegram_user_id
  -> request validation / thin adapter
  -> backend/read-model boundary
```

## API-3A production inventory — COMPLETE

Read-only preflight completed against fresh active/version-consistent production workflows.

Active HTTP surface: **8 endpoints**.

| Method | Path | Workflow |
|---|---|---|
| GET | `/api/v1/dashboard` | `7TJ2xQTxLsTydXZc` |
| GET | `/api/v1/accounts` | `7TJ2xQTxLsTydXZc` |
| GET | `/api/v1/i18n` | `7TJ2xQTxLsTydXZc` |
| GET | `/api/v1/me` | `7TJ2xQTxLsTydXZc` |
| DELETE | `/api/v1/transaction` | `MTxDel7Qp2Vn9Kc4` |
| GET | `/api/v1/transaction-reference` | `MTxRef4Qp8Lm2Xs6` |
| GET | `/api/v1/transactions` | `UX022TxApi202608` |
| GET | `/api/v1/accounts-explorer-summary` | `UX022Summary202608` |

Inventory findings:

- auth-related Code nodes: **8**;
- distinct full-node auth fingerprints: **5**;
- nodes containing `auth_date`: **0/8**;
- nodes performing a clock/freshness check: **0/8**;
- exception-style auth nodes: **6**;
- handled HTTP-error auth nodes: **2**;
- every path derived `telegram_user_id` only after HMAC verification;
- `MONEYTRACK_BOT_TOKEN` present in n8n runtime without exposing its value;
- global active direct business writers: **0**;
- n8n health: **PASS**.

## Frozen freshness policy

MoneyTrack API-3B policy:

- `MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS` — default **86400** seconds (24 hours);
- `MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS` — default **300** seconds (5 minutes).

Both are runtime-configurable. Defaults remain active when environment variables are absent or invalid.

## Canonical auth error vocabulary

- `INIT_DATA_MISSING` — 401;
- `INVALID_INIT_DATA` — 401;
- `HASH_MISSING` — 401;
- `INVALID_INIT_DATA_HASH` — 401;
- `AUTH_DATE_MISSING` — 401;
- `AUTH_DATE_INVALID` — 401;
- `AUTH_DATE_IN_FUTURE` — 401;
- `AUTH_DATE_EXPIRED` — 401;
- `USER_MISSING` — 401;
- `INVALID_USER_DATA` — 401;
- `BOT_TOKEN_MISSING` — 500.

Authentication failures use the canonical API-2B envelope:

```json
{
  "ok": false,
  "error": {
    "code": "AUTH_DATE_EXPIRED"
  }
}
```

## API-3B implementation model

The repository owns one canonical verifier source fragment, version marker `api3b-v1`. A deterministic transformer injects that exact verifier implementation into every active auth path.

Physical topology remains workflow-local because MoneyTrack has no established reusable Execute Sub-workflow auth boundary. This avoids creating a new cross-workflow runtime dependency solely for auth hardening.

For the six former exception-style auth paths, API-3B replaced thrown auth failures with handled output plus an IF auth gate and canonical auth-error responder. Original success downstream paths were preserved.

Transactions and Explorer Summary retained their existing request-validation graphs; only the embedded auth segment was replaced.

## API-3B production evidence — COMPLETE

Successful production cutover ran from the post-rollback baseline and passed every gate.

Production workflow versions:

| Workflow | Before | After | Result |
|---|---:|---:|---|
| MiniApp API `7TJ2xQTxLsTydXZc` | 481 | 482 | PASS |
| Delete `MTxDel7Qp2Vn9Kc4` | 5 | 6 | PASS |
| Transaction Reference `MTxRef4Qp8Lm2Xs6` | 6 | 7 | PASS |
| Transactions `UX022TxApi202608` | 9 | 10 | PASS |
| Explorer Summary `UX022Summary202608` | 8 | 9 | PASS |

Candidate and production gates:

- tooling compile: PASS;
- canonical verifier fragment gate: PASS;
- fresh active/version-consistent identity: PASS 5/5;
- structural auth isolation: PASS 5/5;
- canonical auth nodes: **8/8**;
- exception-style canonical auth nodes: **0**;
- production PUT: PASS 5/5;
- production/candidate node + connection parity: PASS 5/5;
- request validation unchanged for Transactions/Summary: PASS;
- backend/Postgres nodes unchanged: PASS.

Missing-auth smoke across all 8 active HTTP endpoints:

```text
HTTP 401
{"ok":false,"error":{"code":"INIT_DATA_MISSING"}}
```

Result: **PASS 8/8**.

Signed freshness smoke used the runtime bot token without printing its value:

- freshly signed initData with a synthetic unknown Telegram user reached the backend and returned `404 USER_NOT_FOUND` — signature/auth accepted;
- signed initData older than the 24-hour default returned `401 AUTH_DATE_EXPIRED`;
- signed initData more than 5 minutes in the future returned `401 AUTH_DATE_IN_FUTURE`;
- temporary signed payload files were removed after the smoke.

Final invariants:

- global active direct business writers: **0**;
- n8n health: **PASS**.

## Auth contract now active

Every in-scope HTTP request:

1. obtains raw Telegram `initData` only from supported transport inputs;
2. rejects missing auth material;
3. parses query-string data before trusting decoded user fields;
4. verifies Telegram `hash` with bot token and HMAC-SHA-256;
5. uses constant-time hash comparison;
6. requires a positive integer `auth_date`;
7. rejects future-skew/outdated auth data according to MoneyTrack policy;
8. parses the verified Telegram user object;
9. derives `telegram_user_id` only from verified data;
10. returns stable auth error codes/statuses;
11. never trusts caller-provided Telegram identity.

## API-3C — Ownership / Idempotency Gate

API-3C is intentionally narrow.

It must:

- enumerate the retained HTTP write surface after API-3B;
- prove ownership is enforced inside the backend/domain write boundary;
- determine retry/idempotency behavior from the actual write semantics;
- add idempotency machinery only if a concrete duplicate-effect risk exists;
- avoid adding idempotency infrastructure to read-only endpoints.

Expected retained HTTP write candidate from prior inventory is `DELETE /api/v1/transaction`, but API-3C must reassert this from fresh runtime evidence rather than assume it.

## Invariants

API-3 must not:

- change finance/receipt/user/budget/FX semantics;
- rename retained HTTP endpoints;
- change response business fields inside `data`;
- reopen BE-DOM or API-2 work;
- add direct n8n business-table writes;
- trust `initDataUnsafe` or caller-supplied user identity;
- reintroduce `/moneytrack-test`.

## Gate

API-3 closes only when:

- canonical auth protects all active HTTP endpoints — PASS;
- HMAC verification correct — PASS;
- `auth_date` freshness enforced — PASS;
- stable auth errors active — PASS;
- verified identity is the only HTTP identity source — PASS;
- ownership/idempotency review has no blocking debt — PENDING API-3C;
- global direct business writers remain `0` — PASS;
- n8n health PASS — PASS.

## Next

API-3C — Ownership / Idempotency Gate.

After API-3 closes:

- API-4 — final API integration gate and stable API baseline.
