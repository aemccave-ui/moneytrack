# API-1 — API Inventory & Contract Baseline

## Status

CURRENT

## Goal

Establish one canonical inventory of MoneyTrack HTTP API contracts before any request/response normalization or auth hardening.

API-1 is discovery and documentation only. It must not change endpoint behavior, n8n workflow topology, PostgreSQL domain semantics, frontend behavior, or production data.

## Architecture invariant

```text
MiniApp / external HTTP consumer
        -> stable HTTP contract
        -> thin n8n adapter
        -> backend/read-model boundary
        -> PostgreSQL
```

Telegram command workflows remain a separate channel adapter and are not automatically classified as REST API endpoints unless they expose an active HTTP Webhook node.

## Inventory dimensions

Every active HTTP endpoint must be mapped across these dimensions:

1. HTTP method and path.
2. Active workflow ID/name and version consistency.
3. Webhook authentication and response mode.
4. Frontend/source consumers.
5. PostgreSQL nodes used by the endpoint.
6. Backend `_v1` function calls.
7. Direct read SQL retained in the adapter.
8. Code nodes retained in the adapter.
9. Direct business-table writers — required to remain zero.
10. Duplicate method/path collisions.

## Classification

PostgreSQL nodes in HTTP workflows are classified as:

- `BACKEND_BOUNDARY` — delegates to a `moneytrack.*_v1(...)` backend/read-model boundary.
- `DIRECT_READ_SQL` — reads `moneytrack.*` tables directly from n8n.
- `SQL_OTHER` — SQL exists but is neither a recognized backend-boundary call nor a direct MoneyTrack table read.
- `EMPTY_OR_NON_QUERY_OPERATION` — Postgres node without query text.

`DIRECT_READ_SQL` is not automatically a defect in API-1. It is an input to API-2/API-3 prioritization. Direct business-table mutations remain prohibited.

## Known runtime anchors

These IDs are historical anchors to verify against runtime; they are not assumed to be the complete API inventory:

- `7TJ2xQTxLsTydXZc` — MiniApp API.
- `MTxDel7Qp2Vn9Kc4` — MiniApp transaction delete.
- `MTxRef4Qp8Lm2Xs6` — MiniApp transaction reference.
- `UX022Summary202608` — Accounts Explorer summary.
- `UX022TxApi202608` — Transactions API.

## Source refs included in consumer inventory

API-1 compares API consumers in the currently relevant frontend refs when present:

- `origin/main`
- `origin/fix/restore-modern-preview-ui-20260806`
- `origin/agent/ux-022-accounts-explorer`

This is intentional because active/preview frontend work has historically existed outside canonical `main` while backend-domain work was merged separately.

## Gate

API-1 can close when one bounded runtime inventory establishes:

- all active HTTP Webhook endpoints;
- no duplicate active method/path ownership unless explicitly documented;
- endpoint -> workflow -> database/backend-boundary mapping;
- endpoint -> frontend consumer evidence where a repository consumer exists;
- direct active business writers remain `0`;
- n8n health remains PASS;
- each endpoint is assigned one API-2 disposition:
  - `KEEP_AS_IS`,
  - `NORMALIZE_CONTRACT`,
  - `MOVE_READ_MODEL`,
  - `AUTH_HARDEN`,
  - `DEPRECATE_OR_MERGE`.

## Out of scope

API-1 does not:

- rename endpoints;
- change request or response payloads;
- add auth checks;
- migrate direct read SQL;
- change MiniApp code;
- change Telegram behavior;
- execute write-path smoke tests;
- reopen BE-DOM-001..005.

## Next phases

After API-1:

- API-2 — Request/Response Contract Normalization.
- API-3 — Auth / Ownership / Idempotency hardening.
- API-4 — Integration Gate and stable API baseline.
