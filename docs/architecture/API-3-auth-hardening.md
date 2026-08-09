# API-3 — Auth Hardening

## Status

CURRENT — API-3A COMPLETE; API-3B implementation/cutover

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

## Telegram validation baseline

MoneyTrack validates Telegram `initData` server-side using the Telegram HMAC validation scheme before trusting user data. API-3 additionally requires freshness validation using `auth_date`.

Telegram defines `auth_date` as the Unix time associated with the Mini App init data and recommends checking it to reject outdated data, but Telegram does not define MoneyTrack's maximum accepted age. MoneyTrack therefore owns this operational policy.

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
- every path derives `telegram_user_id` only after HMAC verification: **PASS**;
- webhook-level authentication remains `none` for all 8 endpoints because Telegram InitData authentication is application-level;
- `MONEYTRACK_BOT_TOKEN` is present in runtime without exposing its value;
- global active direct business writers: **0**;
- n8n health: **PASS**.

The four MiniApp API verifier nodes share one identical implementation fingerprint. Delete and Reference each have their own implementation, while Transactions and Explorer Summary combine request validation and Telegram auth in distinct Code nodes.

## Frozen freshness policy

MoneyTrack API-3B policy:

- `MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS` — default **86400** seconds (24 hours);
- `MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS` — default **300** seconds (5 minutes).

Both are runtime-configurable. The defaults remain active when the environment variables are absent or invalid, so API correctness does not depend on a deployment-time config mutation.

Rationale: Telegram requires/recommends validating `auth_date` but does not prescribe a TTL. A 24-hour default is compatibility-first: it removes indefinite replay while avoiding unexpectedly short MiniApp session validity. The policy can be tightened later without editing workflow code.

## Canonical auth error vocabulary

API-3B freezes the following machine-readable auth errors:

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

The repository owns one canonical verifier source fragment. A deterministic transformer injects that exact verifier implementation into every active auth path.

Physical topology remains intentionally workflow-local because the current MoneyTrack repository/runtime has no established reusable Execute Sub-workflow auth boundary. Introducing a new cross-workflow runtime dependency solely for auth would add a new failure topology during hardening.

Canonicalization therefore means:

- one repository source of verifier semantics;
- one HMAC implementation;
- one freshness implementation;
- one error vocabulary;
- deterministic structural verification that every active path contains the canonical verifier version.

For the six current exception-style auth nodes (`MiniApp API` x4, Delete, Reference), API-3B replaces thrown auth failures with handled output plus an IF auth gate and canonical `Respond to Webhook` auth-error branch. The original successful downstream path is preserved byte-for-byte.

Transactions and Explorer Summary already have an IF request-valid branch and handled error responder. Their request-validation semantics and graph stay unchanged; only the embedded Telegram-auth implementation is replaced by the canonical verifier fragment.

## Auth contract target

Every in-scope HTTP request must:

1. obtain raw Telegram `initData` only from the supported transport inputs;
2. reject missing auth material;
3. parse the query-string representation without trusting decoded user data before verification;
4. require and verify Telegram `hash` using bot token and HMAC-SHA-256;
5. compare hashes with constant-time buffer comparison where possible;
6. require a positive integer `auth_date`;
7. reject future-skew/outdated auth data according to the frozen MoneyTrack policy;
8. parse the verified Telegram user object;
9. derive `telegram_user_id` only from verified data;
10. return stable auth error codes/statuses through the canonical API envelope;
11. never trust caller-provided Telegram user identity.

## API-3 subphases

### API-3A — Auth Contract & Duplication Inventory

**COMPLETE.**

### API-3B — Canonical Verifier + Cutover

Current scope:

- canonical verifier source + deterministic transformer;
- handled auth-error control-flow for six exception-style paths;
- embedded canonical auth in Transactions/Summary validators;
- configurable `auth_date` freshness;
- exact candidate/production structural verification;
- missing-auth `401` contract smoke across all 8 endpoints;
- signed current/expired initData smoke without printing the bot token;
- preserve endpoint methods/paths, backend queries/functions, business fields and domain semantics.

### API-3C — Ownership / Idempotency Gate

Review the retained HTTP write surface after auth hardening:

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
- trust `initDataUnsafe` or caller-supplied user identity;
- reintroduce `/moneytrack-test`.

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
