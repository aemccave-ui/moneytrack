# API-3C — Ownership / Idempotency Gate

## Status

CURRENT — read-only gate

## Base

API-3A and API-3B are complete. Canonical Telegram InitData authentication is active across all 8 HTTP endpoints, including configurable `auth_date` freshness and stable handled auth errors.

## Goal

Close API-3 by proving that the retained HTTP write surface:

1. derives identity only from verified Telegram InitData;
2. delegates mutation to backend/domain boundaries;
3. enforces ownership at the backend/domain boundary;
4. cannot create duplicate effects on ordinary retry, or has explicit idempotency where required.

## Scope

API-3C is intentionally narrow.

Expected retained HTTP write candidate from prior inventory:

- `DELETE /api/v1/transaction` — workflow `MTxDel7Qp2Vn9Kc4`.

This expectation must be reasserted from fresh production runtime rather than assumed.

Read-only endpoints do not receive idempotency machinery.

## Decision rule

For every active HTTP mutation endpoint:

- identify the exact workflow owner;
- identify the exact backend/domain boundary called;
- prove the workflow contains no direct business-table mutation;
- inspect the backend function signature and implementation;
- prove target-row ownership is constrained by the authenticated user identity at the backend boundary;
- classify retry semantics.

For a DELETE operation, a repeated request does not require an idempotency key if the backend mutation is state-idempotent: after the first successful deletion, repeating the same authenticated delete cannot create an additional business effect. The second response may differ (for example not-found) while the resulting business state remains the same.

A separate idempotency store/key is required only if a concrete retained write can create duplicate business effects on retry.

## Gate

API-3C closes when fresh evidence proves:

- retained active HTTP mutation surface is fully enumerated;
- each mutation delegates to a backend/domain boundary;
- backend ownership enforcement is present;
- retry/idempotency classification has no blocking duplicate-effect risk;
- global active direct business writers remain `0`;
- canonical API-3B auth remains active;
- n8n health PASS.

If the only retained mutation is ownership-scoped transaction DELETE and it is state-idempotent, API-3C requires no production mutation.

## Out of scope

- adding idempotency keys to GET endpoints;
- changing transaction/business semantics;
- changing API paths or response fields;
- reopening API-2 or BE-DOM work;
- production hardening unrelated to API correctness.

## Next

After API-3C closes:

- API-3 — CLOSED;
- API-4 — final API integration gate / stable API baseline.
