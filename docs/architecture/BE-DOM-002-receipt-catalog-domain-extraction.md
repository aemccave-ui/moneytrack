# MoneyTrack — BE-DOM-002 — Receipt / Catalog Domain Extraction

## Status

**COMPLETE — PRODUCTION CUTOVER PASS / RUNTIME SMOKE PASS / MERGE PENDING**

## Goal

Move receipt/catalog business writes out of active n8n workflows into PostgreSQL backend boundaries while preserving the existing Telegram/Photo workflow topology and downstream output contracts.

Target dependency direction:

```text
Telegram / MiniApp
↓
n8n transport / orchestration
↓
PostgreSQL domain entry points
↓
Persistence
```

## Scope

Target persistence surfaces:

- `moneytrack.receipts`
- `moneytrack.receipt_items`
- `moneytrack.product_catalog`
- `moneytrack.category_catalog`
- related catalog translations where required by bootstrap

The existing Finance Domain (`BE-DOM-001`) remains canonical for financial transaction creation.

## Backend boundaries

BE-DOM-002 introduces:

```text
moneytrack.catalog_ensure_user_categories_v1(bigint)
moneytrack.receipt_ingest_v1(bigint,bigint,numeric,text,text,date,text,text,jsonb,jsonb)
moneytrack.receipt_assign_categories_v1(bigint,bigint,jsonb)
moneytrack.receipt_set_item_category_v1(bigint,bigint,text)
```

### Responsibilities

`catalog_ensure_user_categories_v1`

- serializes per-user category bootstrap;
- copies the canonical template-user category hierarchy;
- copies translations;
- is idempotent for repeated bootstrap.

`receipt_ingest_v1`

- owns exact duplicate protection by Telegram file identity;
- owns semantic duplicate protection by user + receipt fingerprint;
- serializes duplicate identity checks;
- creates the finance transaction through `finance_create_transaction_v1`;
- creates receipt persistence;
- resolves/upserts products;
- creates receipt items;
- validates user/category/language ownership constraints;
- executes the aggregate as one PostgreSQL transaction.

`receipt_assign_categories_v1`

- validates receipt ownership;
- applies product/category assignments;
- propagates product categories into uncategorized receipt items atomically.

`receipt_set_item_category_v1`

- owns manual item-category mutation semantics;
- enforces user/receipt/product/category ownership;
- preserves the existing adapter result contract.

## Verification

Repository verifier:

```text
db/domain/BE-DOM-002/011_verify_receipt_catalog_domain.sql
```

The rollback-safe verifier covers:

- category bootstrap and repeated bootstrap;
- exact duplicate replay;
- semantic duplicate replay;
- transaction + receipt + product + item creation;
- category propagation;
- manual item-category mutation;
- tenant isolation;
- aggregate rollback when an item references a foreign category;
- synthetic fixture cleanup by outer transaction rollback.

Backend installation gate passed with all four functions present and zero synthetic leaks.

## n8n cutover

The workflow topology was preserved. Only `parameters.query` changed in the selected nodes.

### Main workflow

`DER2Lc3dT2afyQhy` (`MoneyTrack`)

- `Get or Create User` → `catalog_ensure_user_categories_v1`
- `Set Item Category` → `receipt_set_item_category_v1`

### Photo workflow

`5VC0EcFB21rwTfoI` (`MoneyTrack Transaction Processor Photo`)

- `Insert transaction` → `receipt_ingest_v1` and remains the compatibility source of transaction/receipt IDs;
- `Update product category` → `receipt_assign_categories_v1`;
- legacy `Insert receipt`, `Create products`, `Insert receipt items`, and `Update receipt item categories TRUE` became read-only compatibility adapters.

Structural candidate gate:

```text
Main node count              142
Photo node count             46
Main graph SHA-256           59af0ac4fefedcd3d96d9eb483e2dc3ef99713e237dad47b45b8ee5619f7279f
Photo graph SHA-256          574299b009fe0119d4c6eb5cbe584d36aea5de694a3ceebe0fecffcc7b4fe113
Direct target writer bypass  0
Status                       PASS
```

## Production cutover evidence — 2026-08-08

Pre-cutover drift gate passed for both workflows.

Production workflow versions after cutover:

```text
MoneyTrack
versionId       7b1a47e0-3cb3-4946-8f65-a965a7455b23
activeVersionId 7b1a47e0-3cb3-4946-8f65-a965a7455b23
versionCounter  4002

MoneyTrack Transaction Processor Photo
versionId       6925d73f-72aa-4d1d-a2a7-86b54b5daf4d
activeVersionId 6925d73f-72aa-4d1d-a2a7-86b54b5daf4d
versionCounter  164
```

Both Public API PUT operations returned HTTP 200. Candidate node parity passed for both workflows. n8n restart/health gate passed. Global active direct-writer scan for receipt/catalog target tables returned zero rows.

## Production Photo runtime smoke

Execution:

```text
Photo execution ID  133032
workflow             5VC0EcFB21rwTfoI
status               success
```

Created aggregate:

```text
receipt_id            194
transaction_id        1122
user_id               1
shop                   MERCADONA, S.A.
receipt_total          19.10 EUR
transaction_total      19.10 EUR
receipt_items          11
linked_products        11
```

Runtime aggregate consistency query returned zero violations.

Creation counts relative to the pre-smoke baseline:

```text
new_receipts       1
new_transactions   1
new_receipt_items  11
```

Post-smoke global active direct-writer scan returned zero rows and:

```text
direct_receipt_catalog_bypass = 0
```

## Final gate before merge

```text
Backend implementation            PASS
Rollback-safe verifier            PASS
Candidate structural isolation    PASS
Adapter output compatibility      PASS
Production drift protection       PASS
Main production cutover           PASS
Photo production cutover          PASS
n8n restart / health              PASS
Runtime Photo smoke               PASS
Aggregate consistency             PASS
Active receipt/catalog bypass     0
```

## Definition of done

BE-DOM-002 is complete when this branch is merged to canonical `main` and the short post-merge gate confirms:

- canonical `main` contains the BE-DOM-002 tree;
- all four backend functions remain installed;
- Main and Photo remain active and version-consistent;
- global active receipt/catalog direct-writer bypass remains zero.

No further BE-DOM-002 refactoring is required after that gate.