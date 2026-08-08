# BE-DOM-001 — Photo CreateTransaction Repository Cutover

Date: 2026-08-08

## Status

**PASS — REPOSITORY + RUNTIME PHOTO WRITE SLICE**

The `MoneyTrack Transaction Processor Photo` workflow (`5VC0EcFB21rwTfoI`) now delegates its financial transaction write to the canonical backend boundary:

```text
moneytrack.finance_create_transaction_v1(...)
```

## Scope

Only the SQL implementation of the Photo workflow node:

```text
Insert transaction
```

was changed.

The following remained structurally unchanged in the candidate workflow:

- `Insert receipt`;
- receipt duplicate checks;
- `receipt_items`;
- `product_catalog`;
- categorization;
- workflow topology;
- node connections;
- unrelated expressions and nodes.

## Canonical adapter SQL

The active query is:

```sql
select
    c.*
from moneytrack.finance_create_transaction_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('Resolve account').first().json.account_id }}::bigint,
    'expense'::text,
    {{ $('Parse receipt JSON').first().json.total_amount }}::numeric,
    '{{ String($('Parse receipt JSON').first().json.currency || "").replace(/'/g,"''") }}'::text,
    '{{ String($('Parse receipt JSON').first().json.shop_name || "").replace(/'/g,"''") }}'::text,
    coalesce(
        nullif(
            nullif(
                nullif('{{ $('Parse receipt JSON').first().json.receipt_date }}', ''),
                'null'
            ),
            'undefined'
        )::timestamptz,
        current_timestamp
    ),
    null,
    null,
    null
) c;
```

The adapter supplies only transaction intent:

- internal `user_id` from the Photo processor input contract;
- `account_id` from `Resolve account`;
- transaction type `expense`;
- original amount and currency from `Parse receipt JSON`;
- description from `shop_name`;
- receipt date when present, otherwise current timestamp;
- `p_source_type = NULL`;
- `p_source_id = NULL`;
- `p_category_id = NULL`.

It does not calculate or pass `amount_base`, `currency_base`, or `exchange_rate`. Those values are backend/domain responsibilities.

## Deterministic transformation

Repository script:

```text
scripts/be-dom-001-transform-photo-write.py
```

accepts either a workflow object or the one-element array produced by `n8n export:workflow` and rejects an unexpected workflow id, missing/duplicate target node, or a target node that is not `executeQuery`.

It deep-copies the source workflow and replaces only `Insert transaction.parameters.query`.

## Verification gate

Repository script:

```text
scripts/be-dom-001-verify-photo-write.py
```

compares source and candidate exports and fails unless all of the following are true:

1. both documents are the expected Photo workflow;
2. exactly one `Insert transaction` target exists;
3. the candidate query equals the canonical repository query;
4. `finance_create_transaction_v1` is called;
5. no direct `INSERT INTO moneytrack.transactions` remains in the candidate target query;
6. `amount_base`, `currency_base`, and `exchange_rate` are absent from the adapter query;
7. after restoring only the target query to its source value, the entire parsed candidate document equals the entire parsed source document.

External runtime-export verification also passed with normalized structural diff:

```text
diff_exit=0
```

## Runtime cutover evidence — 2026-08-08

Pre-cutover production Photo workflow:

```text
workflow_id      = 5VC0EcFB21rwTfoI
versionId        = 3ee7eadd-c06e-432b-938b-1757897791cf
activeVersionId  = 3ee7eadd-c06e-432b-938b-1757897791cf
versionCounter   = 162
nodes            = 46
```

The production export contained exactly one direct `INSERT INTO moneytrack.transactions` node:

```text
Insert transaction
```

The generated candidate passed the repository verifier and normalized isolation diff. The n8n Public API update returned HTTP 200 and created active version:

```text
versionId        = 21c14ab6-0ef3-4b13-94ee-ff4e945881d8
activeVersionId  = 21c14ab6-0ef3-4b13-94ee-ff4e945881d8
versionCounter   = 163
active           = true
```

Database workflow history confirmed the new active version. The active `Insert transaction` node contains the canonical `finance_create_transaction_v1(...)` call.

After restart:

```text
container running    = true
restart_count        = 0
healthz              = {"status":"ok"}
Photo workflow       = activated
```

The early `connection reset by peer` observed immediately after restart occurred during n8n startup and was not a workflow failure.

### Production receipt smoke

A real Telegram receipt followed the production chain:

```text
MoneyTrack main workflow
→ MoneyTrack Transaction Processor Photo
→ finance_create_transaction_v1(...)
→ moneytrack.transactions
→ receipt persistence
```

Executions:

```text
132986  DER2Lc3dT2afyQhy  success  webhook
132987  5VC0EcFB21rwTfoI  success  integrated
```

A new financial posting and linked receipt were persisted:

```text
transaction id       = 1115
transaction_type     = expense
amount_original      = 21.10
currency_original    = EUR
amount_base          = 21.10
currency_base        = EUR
exchange_rate        = 1.00000000
account_id           = 6
account_code         = freedom.eur
account_currency     = EUR
description          = MERCADONA, S.A.
receipt_id           = 189
receipt_fingerprint  = mercadonasa|2026-08-06|21.10|EUR|12
```

Because both the source and user base currency are EUR, `exchange_rate=1` is the correct backend result for this smoke. A prior Text Processor production smoke independently proved the same backend boundary performs non-base-currency valuation (`10 USD -> 8.66 EUR`, rate `0.865666`).

The post-smoke n8n log scan contained no Photo/finance runtime errors.

## Architectural debt deliberately retained

### Receipt aggregate atomicity

Receipt aggregate creation is **not yet a single atomic domain operation**.

The Photo flow still persists receipt-related state separately from the canonical financial transaction command. A failure between receipt persistence and transaction posting can therefore still leave cross-aggregate partial state. Solving that requires a dedicated receipt/domain transaction-boundary design and is not part of this cutover.

### Duplicate protection remains adapter-level

Current receipt duplicate protection remains in the Photo adapter/workflow. It has not been promoted into the canonical finance write boundary by this slice.

### Photo source idempotency is not yet canonical

The runtime Photo flow has text source identities such as Telegram file identity and/or receipt fingerprint semantics, while `moneytrack.transactions.source_id` and `finance_create_transaction_v1.p_source_id` are `bigint`.

Passing `source_type='receipt'` without a `source_id` is invalid because the backend rejects incomplete source identity. Therefore this cutover deliberately passes:

```text
p_source_type = NULL
p_source_id   = NULL
```

End-to-end Photo posting idempotency remains deferred until a stable source identity representation is designed that is compatible with the backend contract.

## Gate

```text
Repository transformer          PASS
Repository isolation verifier   PASS
Production runtime export       PASS
External normalized diff        PASS
n8n API cutover                 PASS
Active version verification     PASS
Restart / health                PASS
Workflow activation             PASS
Production receipt smoke        PASS
Post-cutover error scan          PASS

PHOTO FINANCIAL WRITE SLICE      PASS
```

## Next step

Proceed to the transfer write boundary. The current Text Processor `Insert transfer` node still writes directly to `moneytrack.transfers`, so transfer ownership, type validation, account/currency rules, atomicity, and idempotency still need a canonical backend owner before BE-DOM-001 can close.
