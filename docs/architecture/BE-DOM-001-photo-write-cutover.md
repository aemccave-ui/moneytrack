# BE-DOM-001 — Photo CreateTransaction Repository Cutover

Date: 2026-08-08

## Status

**CODED — RUNTIME CUTOVER NOT PERFORMED**

This slice prepares the `MoneyTrack Transaction Processor Photo` workflow (`5VC0EcFB21rwTfoI`) to delegate its financial transaction write to the canonical backend boundary:

```text
moneytrack.finance_create_transaction_v1(...)
```

This repository change does not update, publish, restart, execute, or otherwise mutate the production n8n runtime.

## Scope

Only the SQL implementation of the Photo workflow node:

```text
Insert transaction
```

may change.

The following remain outside this slice and must remain structurally unchanged in the candidate workflow:

- `Insert receipt`;
- receipt duplicate checks;
- `receipt_items`;
- `product_catalog`;
- categorization;
- workflow topology;
- node connections;
- unrelated expressions and nodes.

## Canonical adapter SQL

The candidate query is:

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

The adapter therefore supplies only transaction intent:

- internal `user_id` from the current Photo processor input contract;
- `account_id` from `Resolve account`;
- transaction type `expense`;
- original amount and currency from `Parse receipt JSON`;
- description from `shop_name`;
- receipt date when present, otherwise current timestamp;
- `p_source_type = NULL`;
- `p_source_id = NULL`;
- `p_category_id = NULL`.

It does not calculate or pass `amount_base`, `currency_base`, or `exchange_rate`. Those values remain backend/domain responsibilities.

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

The final condition protects topology, connections, node parameters, receipt logic, categorization, and all unrelated expressions from accidental edits.

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
Repository transformer          CODED
Repository isolation verifier   CODED
Architecture debt               RECORDED
Runtime workflow export         NOT MUTATED
Production n8n update           NOT PERFORMED
Production smoke                NOT PERFORMED

PHOTO REPOSITORY SLICE          READY FOR EXTERNAL WORKFLOW EXPORT VERIFICATION
```

No runtime mutation was performed as part of this repository slice.
