# BE-DOM-001 — Text CreateTransaction Runtime Evidence

Date: 2026-08-08

## Gate

**PASS — Text CreateTransaction production cutover**

## Runtime path

```text
Telegram
→ MoneyTrack main workflow (DER2Lc3dT2afyQhy)
→ MoneyTrack Transaction Processor Text (f5ioJKyPTupUMV9h)
→ moneytrack.finance_create_transaction_v1(...)
→ moneytrack.transactions
```

## n8n version state

Text Processor active version after cutover:

```text
1fe26602-c7e3-4e4d-88bd-998706e04121
```

The workflow remained active and restarted cleanly.

The three transaction writer nodes delegate to the backend domain function:

- Insert transaction text
- Insert adjustment transaction
- Insert opening balance

No unrelated workflow graph change was allowed; the normalized structural diff gate returned `diff_exit=0`.

## Backend gates

The installed `moneytrack.finance_create_transaction_v1(...)` enforces:

- account ownership;
- category ownership;
- transaction type validation;
- amount invariants;
- account/currency consistency;
- base currency derivation;
- backend FX conversion;
- opening-balance uniqueness/replay;
- optional source identity/idempotency semantics.

Rollback-safe verification completed successfully after installation.

## Production smoke

Production smoke command represented an expense of 10 USD on the `cash.usd` account for user 1.

Execution evidence:

```text
Main workflow execution: 132982 — success — webhook
Text Processor execution: 132983 — success — integrated
```

Persisted transaction:

```text
id                = 1113
transaction_type  = expense
amount_original   = 10.00
currency_original = USD
amount_base       = 8.66
currency_base     = EUR
exchange_rate     = 0.86566600
account_id        = 16
account_code      = cash.usd
description       = smoke
```

This proves the production path no longer applies the legacy `amount_base = amount_original`, `currency_base = currency_original`, `exchange_rate = 1` behavior for foreign-currency Text transactions. Base valuation is now performed by the backend domain boundary.

Post-smoke n8n error scan returned no relevant errors.

## Known debt

The current Text Processor input contract does not expose a proven stable Telegram `message_id` or `update_id` to the transaction writer. The cutover therefore currently calls the backend with `source_type = NULL` and `source_id = NULL`.

Backend idempotency enforcement exists, but transport-level stable source identity still needs to be propagated before Telegram Text posting is end-to-end idempotent.

## Remaining BE-DOM-001 write work

- Photo transaction writer cutover;
- transfer write boundary;
- update / set-account boundary;
- delete transaction boundary;
- stable source identity propagation;
- final write-side regression and runtime gates.
