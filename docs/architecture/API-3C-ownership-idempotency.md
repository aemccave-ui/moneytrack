# API-3C — Ownership / Idempotency Gate

## Status

COMPLETE — READ-ONLY GATE PASS / NO PRODUCTION MUTATION REQUIRED

## Base

API-3A and API-3B are complete. Canonical Telegram InitData authentication is active across all 8 HTTP endpoints, including configurable `auth_date` freshness and stable handled auth errors.

## Goal

Close API-3 by proving that the retained HTTP write surface:

1. derives identity only from verified Telegram InitData;
2. delegates mutation to backend/domain boundaries;
3. enforces ownership at the backend/domain boundary;
4. cannot create duplicate effects on ordinary retry, or has explicit idempotency where required.

## Production evidence

The fresh read-only API-3C preflight completed with all gates PASS.

### Retained HTTP write surface

Exactly one active retained API mutation exists:

| Method | Path | Workflow | Version |
|---|---|---|---:|
| DELETE | `/api/v1/transaction` | `MTxDel7Qp2Vn9Kc4` | 6 |

`retained_api_mutation_endpoint_count=1` and `retained_write_surface=PASS`.

The Delete workflow is active and version-consistent.

### Workflow boundary

The workflow contains one Postgres node, `Delete Transaction`, and delegates mutation exactly once to:

```text
moneytrack.finance_delete_transaction_v1(
  authenticated_user_id,
  transaction_id
)
```

The adapter resolves `telegram_user_id` to internal `user_id`, then calls the backend function. The workflow contains no direct business-table mutation.

Canonical `api3b-v1` authentication remains active in `Verify Telegram InitData delete`.

### Backend function identity

Backend boundary:

```text
moneytrack.finance_delete_transaction_v1(bigint,bigint)
```

Arguments:

```text
p_user_id bigint,
p_transaction_id bigint
```

Security mode: `SECURITY INVOKER`.

### Ownership enforcement

The function locks the target transaction using both identifiers:

```sql
where t.id = p_transaction_id
  and t.user_id = p_user_id
for update;
```

If no row matches the authenticated user and requested transaction, it returns `status='not_found'` and performs no mutation.

All aggregate deletes retain the same ownership boundary:

- `receipt_items` are deleted only through receipts where `r.user_id = p_user_id` and `r.transaction_id = v_tx.id`;
- `receipts` are deleted only where `r.user_id = p_user_id` and `r.transaction_id = v_tx.id`;
- the transaction is deleted only where `t.id = v_tx.id` and `t.user_id = p_user_id`.

The function requires exactly one final transaction delete; otherwise it raises a concurrency failure. Receipt rows and the transaction are deleted inside the same backend function invocation.

Result: `backend_ownership_marker_gate=PASS`.

## Retry / idempotency classification

Disposition: **STATE-IDEMPOTENT — NO IDEMPOTENCY KEY/STORE REQUIRED**.

Reason:

1. first successful DELETE locks and deletes the ownership-scoped transaction aggregate;
2. after commit, the transaction no longer exists;
3. repeating the same authenticated DELETE cannot delete or create another business object;
4. the repeated call falls through the ownership-scoped lookup and returns `not_found` without a second mutation.

The HTTP response may differ between the first and repeated call, but the resulting business state is the same. Therefore no duplicate-effect risk exists that would justify an idempotency-key subsystem.

Concurrent duplicate deletes are also bounded by `FOR UPDATE` plus the ownership-scoped recheck/final delete-count guard.

## Final API-3C invariants

- retained HTTP mutation surface fully enumerated: **PASS**;
- retained mutation delegates to backend/domain boundary: **PASS**;
- direct n8n business-table mutation: **0 / PASS**;
- verified Telegram auth remains active: **PASS**;
- backend ownership enforcement: **PASS**;
- duplicate-effect retry risk: **NONE / PASS**;
- separate idempotency machinery required: **NO**;
- global active direct business writers: **0 / PASS**;
- n8n health: **PASS**.

## Decision

API-3C requires no production mutation.

API-3 is ready to close.

## Next

- API-3 — CLOSED;
- API-4 — Final API Integration Gate / stable API baseline.
