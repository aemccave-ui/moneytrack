# MoneyTrack — BE-DOM-001 — Write Domain Forensic

## Status

WRITE FORENSIC BASELINE ESTABLISHED

## Runtime evidence

The active MoneyTrack runtime contains multiple write-capable n8n workflows. Confirmed direct writers include:

- `MoneyTrack` (`DER2Lc3dT2afyQhy`) — direct `UPDATE` and `DELETE` against `moneytrack.transactions` in command flows;
- `MoneyTrack Transaction Processor Photo` (`5VC0EcFB21rwTfoI`) — direct transaction `INSERT`;
- `MoneyTrack Transaction Processor Text` (`f5ioJKyPTupUMV9h`) — direct transaction `INSERT`;
- `MoneyTrack MiniApp Delete Transaction` (`MTxDel7Qp2Vn9Kc4`) — direct transaction `DELETE`.

Voice does not appear as a direct transaction writer in the first SQL-pattern inventory and must be treated as delegation/orchestration until its actual execution path is proven.

## Persistence contract observed at runtime

### `moneytrack.transactions`

Financially significant columns include:

- `user_id bigint NOT NULL`
- `account_id bigint NULL`
- `transaction_type text NOT NULL`
- `amount_original numeric(14,2) NOT NULL`
- `currency_original text NOT NULL`
- `amount_base numeric(14,2) NULL`
- `currency_base text NULL`
- `exchange_rate numeric(18,8) NULL`
- `category_id bigint NULL`
- `transaction_date timestamptz NOT NULL`
- `source_type text NULL`
- `source_id bigint NULL`
- `transfer_id bigint NULL`

The table currently has foreign keys and a primary key, but no observed unique constraint for source/idempotency semantics such as `(user_id, source_type, source_id)`.

### `moneytrack.transfers`

Financially significant columns include:

- `user_id bigint NOT NULL`
- `from_account_id bigint NULL`
- `to_account_id bigint NULL`
- `from_amount numeric(14,2) NULL`
- `from_currency text NULL`
- `to_amount numeric(14,2) NULL`
- `to_currency text NULL`
- `exchange_rate numeric(18,8) NULL`
- `fee_amount numeric(14,2) NULL`
- `fee_currency text NULL`
- `transfer_date timestamptz NOT NULL`
- `transfer_type text NULL`

There is no `moneytrack.transfer_types` table in the observed runtime. `transfer_type` is therefore not protected by an FK-backed type catalogue.

### Transaction type catalogue

Observed transaction types:

- `adjustment`
- `exchange`
- `expense`
- `income`
- `openingbalance`
- `transfer`
- `transferexchange`

## Confirmed write-path architecture debt

### W-001 — Direct financial DML from n8n

Severity: CRITICAL

Production workflows perform direct `INSERT`, `UPDATE`, and `DELETE` against financial persistence. This means ownership checks, amount semantics, FX/base valuation, duplicate protection and mutation atomicity can vary per workflow.

Target: n8n must call versioned backend/domain entry points instead of owning financial DML.

### W-002 — Backend ownership is not universally enforced

Severity: CRITICAL

Several observed workflow queries do scope mutations by `user_id`, but this is workflow-local protection. A new or incorrectly edited workflow can bypass it because persistence itself does not enforce caller ownership.

Target: every financial command entry point must require internal `user_id` and resolve/validate target entities against that owner before mutation.

### W-003 — Base valuation fields are nullable and caller-writable

Severity: HIGH

`amount_base`, `currency_base`, and `exchange_rate` are nullable persistence fields. Existing writers can populate them directly.

Target: n8n must not supply authoritative base amount/rate values. Backend logic derives them from original amount/currency, user base currency, transaction date and canonical FX policy.

### W-004 — Idempotency is not persistence-enforced

Severity: CRITICAL

No observed unique key protects transaction posting by source/idempotency identity. `source_type` and `source_id` are nullable and unconstrained as a pair.

Target: introduce an explicit idempotency contract before write cutover. The exact key must be based on real source semantics; do not add a naive unique constraint until legacy duplicates/null semantics have been audited.

### W-005 — Transfer invariants are weakly represented

Severity: CRITICAL

Transfer columns are mostly nullable, and `transfer_type` has no catalogue FK. Persistence does not prove that from/to accounts belong to the caller, currencies match account currencies, amounts are positive, or cross-currency amounts/rates are coherent.

Target: transfers are created atomically through one backend entry point that validates both accounts and computes/validates conversion semantics.

### W-006 — Delete/update semantics are workflow-local

Severity: HIGH

Observed flows perform direct transaction account reassignment and transaction deletion. Some scope by user and delete linked receipt data in the same SQL statement, but the protection is not reusable backend policy.

Target: introduce dedicated backend commands for update/set-account/delete, including ownership validation and linked receipt cleanup semantics.

## Required backend boundary

The target write API is conceptually:

```text
n8n / future API adapter
        ↓
finance_create_transaction_v1(...)
finance_update_transaction_v1(...)
finance_set_transaction_account_v1(...)
finance_delete_transaction_v1(...)
finance_create_transfer_v1(...)
        ↓
backend/domain validation
        ↓
transactions / transfers / receipts
```

Function signatures remain provisional until the exact Text/Photo/Voice/Transfer source semantics are fully inventoried.

## Mandatory invariants

At minimum, backend write commands must enforce:

1. Caller `user_id` exists.
2. Target account belongs to caller and is active when required.
3. Category, receipt and transaction references cannot cross user ownership boundaries.
4. Transaction type is from the canonical type catalogue and allowed for the command.
5. Original amount/currency are authoritative inputs; derived base values are backend-owned.
6. Account currency and transaction currency compatibility is explicit, not accidental.
7. FX valuation date/policy is deterministic and explicit.
8. Missing required FX is an error for commands that require base valuation; it must not silently become zero/null financial value.
9. Idempotent retries cannot create duplicate financial effects.
10. Update/delete commands require ownership of the target transaction.
11. Transfer creation validates both accounts under the same user and commits atomically.
12. No partial posting remains after any error.

## Separation from account deletion/privacy lifecycle

The `MoneyTrack` workflow also contains a user-data deletion flow that removes receipts, transfers, transactions, budgets, products, categories, accounts, settings and the user record after confirmation.

That is not a transaction-domain delete operation and must not be folded into `finance_delete_transaction_v1`. It requires a separate lifecycle/privacy backend boundary.

## Next gate

Before implementing the first write function:

1. capture the exact direct INSERT implementations used by Text and Photo processors;
2. prove the Voice delegation path;
3. capture the exact transfer creation path;
4. inventory legacy values/nulls/duplicates for source metadata and base valuation fields;
5. define CreateTransaction v1 compatibility semantics;
6. implement and verify the backend function in shadow mode before switching any workflow.
