# API-3 — Auth Hardening

## Status

CURRENT — API-3A inventory/preflight

## Base

API-1, API-2A, API-2B and API-2C are closed and merged. `POST /moneytrack-test` has been removed. The active HTTP surface now consists of retained MiniApp API endpoints plus deprecated-but-active `/api/v1/me`.

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

## Telegram validation baseline

MoneyTrack must continue to validate Telegram `initData` server-side using the Telegram HMAC validation scheme before trusting user data. API-3 additionally requires freshness validation using `auth_date`.

Telegram does not define MoneyTrack's maximum accepted age. API-3 will freeze a MoneyTrack max-age policy after the production inventory, and the value must be configurable rather than duplicated as literals across workflow nodes.

## Scope

API-3 covers all active HTTP MiniApp endpoints, including:

- `GET /api/v1/dashboard`
- `GET /api/v1/accounts`
- `GET /api/v1/i18n`
- `GET /api/v1/me` while it remains active/deprecated
- `DELETE /api/v1/transaction`
- `GET /api/v1/transaction-reference`
- `GET /api/v1/transactions`
- `GET /api/v1/accounts-explorer-summary`

API-3 must not reintroduce `/moneytrack-test`.

## Auth contract target

Every in-scope HTTP request must have one logical authentication policy:

1. obtain raw Telegram `initData` only from the supported transport inputs;
2. reject missing auth material;
3. parse the query-string representation without trusting decoded user data before verification;
4. require and verify the Telegram `hash` using the current bot token and HMAC-SHA-256 scheme;
5. require a numeric `auth_date`;
6. reject future-skew/outdated auth data according to the frozen MoneyTrack policy;
7. parse the verified Telegram user object;
8. derive `telegram_user_id` only from verified data;
9. return stable auth error codes/statuses through the canonical API envelope;
10. never trust a caller-provided Telegram user id.

## API-3 subphases

### API-3A — Auth Contract & Duplication Inventory

Read-only production inventory:

- enumerate every active HTTP webhook;
- identify its auth/verify/validate Code nodes;
- fingerprint verifier implementations;
- prove whether `auth_date` freshness exists or is absent;
- capture current auth error behavior and control-flow;
- verify endpoint ownership/version consistency;
- verify zero direct business writers and n8n health.

### API-3B — Canonical Verifier + Cutover

After API-3A freezes the exact current topology:

- implement one canonical verifier pattern/boundary;
- add configurable `auth_date` freshness policy;
- normalize auth failures to canonical envelope/status;
- cut over all active HTTP endpoints with exact structural verification;
- preserve endpoint methods/paths, backend queries/functions, business fields and domain semantics.

### API-3C — Ownership / Idempotency Gate

Review the retained HTTP write surface after auth centralization:

- prove ownership is enforced at backend/domain boundaries;
- identify any request that can cause duplicate effects on retry;
- add idempotency only where a concrete non-idempotent write path exists;
- do not invent idempotency machinery for read-only endpoints.

## Invariants

API-3 must not:

- change finance/receipt/user/budget/FX semantics;
- rename retained HTTP endpoints;
- change response business fields inside `data`;
- reopen BE-DOM or API-2 work;
- add direct n8n business-table writes;
- trust `initDataUnsafe` or caller-supplied user identity.

## Gate

API-3 closes only when:

- one canonical auth contract protects all active HTTP endpoints;
- HMAC verification remains correct;
- `auth_date` freshness is enforced by frozen configurable policy;
- stable auth error envelopes/statuses are active;
- verified identity is the only identity source;
- ownership/idempotency review has no blocking debt;
- global direct business writers remain `0`;
- n8n health PASS.

## Next

After API-3 closes:

- API-4 — final API integration gate and stable API baseline.
