# API-3 — Auth Hardening

## Status

API-3 — CLOSED

API-3A — COMPLETE

API-3B — COMPLETE / PRODUCTION CUTOVER PASS

API-3C — COMPLETE / READ-ONLY OWNERSHIP-IDEMPOTENCY GATE PASS

## Base

API-1 and API-2 are closed. `POST /moneytrack-test` has been removed. The active HTTP surface consists of seven retained MiniApp API endpoints plus deprecated-but-active `/api/v1/me`.

## Goal

Establish one canonical Telegram MiniApp authentication contract for every active MoneyTrack HTTP endpoint without moving business semantics back into n8n, and prove the retained HTTP write surface is ownership-safe and does not need additional idempotency machinery.

Target architecture:

```text
MiniApp request
  -> canonical Telegram InitData verification
  -> verified telegram_user_id
  -> request validation / thin adapter
  -> backend/read-model or write boundary
```

## API-3A — Inventory COMPLETE

Fresh production inventory established:

- active HTTP endpoints: **8**;
- auth-related Code nodes before hardening: **8**;
- distinct verifier implementations before hardening: **5**;
- `auth_date` checks before hardening: **0/8**;
- clock/freshness checks before hardening: **0/8**;
- exception-style auth before hardening: **6**;
- handled HTTP auth before hardening: **2**;
- global active direct business writers: **0**;
- n8n health: **PASS**.

## Frozen freshness policy

MoneyTrack policy:

- `MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS` — default **86400** seconds (24 hours);
- `MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS` — default **300** seconds (5 minutes).

Both remain runtime-configurable.

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

Authentication failures use the canonical API-2B envelope.

## API-3B — Canonical Verifier + Cutover COMPLETE

The repository owns one canonical verifier source fragment with version marker `api3b-v1`.

Production workflow versions after successful cutover:

| Workflow | Before | After | Result |
|---|---:|---:|---|
| MiniApp API `7TJ2xQTxLsTydXZc` | 481 | 482 | PASS |
| Delete `MTxDel7Qp2Vn9Kc4` | 5 | 6 | PASS |
| Transaction Reference `MTxRef4Qp8Lm2Xs6` | 6 | 7 | PASS |
| Transactions `UX022TxApi202608` | 9 | 10 | PASS |
| Explorer Summary `UX022Summary202608` | 8 | 9 | PASS |

Production gates:

- canonical auth nodes: **8/8**;
- exception-style canonical auth nodes: **0**;
- production PUT: **PASS 5/5**;
- production/candidate parity: **PASS 5/5**;
- request validation unchanged for Transactions/Summary: **PASS**;
- backend/Postgres nodes unchanged: **PASS**;
- missing-auth `401 INIT_DATA_MISSING`: **PASS 8/8**;
- freshly signed initData: **AUTH ACCEPTED / PASS**;
- expired signed initData: **401 AUTH_DATE_EXPIRED / PASS**;
- future signed initData: **401 AUTH_DATE_IN_FUTURE / PASS**;
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

## API-3C — Ownership / Idempotency Gate COMPLETE

Fresh production evidence proved exactly one active retained HTTP mutation:

```text
DELETE /api/v1/transaction
workflow MTxDel7Qp2Vn9Kc4
```

The workflow:

- retains canonical `api3b-v1` authentication;
- contains no direct business-table mutation;
- delegates exactly once to `moneytrack.finance_delete_transaction_v1`.

Backend ownership is enforced by the target lock predicate:

```sql
where t.id = p_transaction_id
  and t.user_id = p_user_id
for update
```

and by ownership predicates on receipt-item, receipt and transaction deletes.

Retry classification:

- first successful DELETE removes the ownership-scoped aggregate;
- a repeated authenticated DELETE finds no matching transaction and produces no additional mutation;
- resulting business state is unchanged after retry;
- concurrent duplicate deletes are bounded by row locking and the final delete-count guard.

Disposition: **STATE-IDEMPOTENT — NO IDEMPOTENCY KEY/STORE REQUIRED**.

API-3C required no production mutation.

## Final API-3 gate

- canonical auth protects all active HTTP endpoints — **PASS**;
- HMAC verification correct — **PASS**;
- `auth_date` freshness enforced — **PASS**;
- stable auth errors active — **PASS**;
- verified identity is the only HTTP identity source — **PASS**;
- retained HTTP write surface fully enumerated — **PASS**;
- backend ownership enforcement — **PASS**;
- blocking duplicate-effect/idempotency debt — **NONE**;
- global direct business writers remain `0` — **PASS**;
- n8n health — **PASS**.

## Decision

**API-3 — CLOSED.**

## Next

- API-4 — Final API Integration Gate / stable API baseline.
