# MoneyTrack — BE-DOM-001 — n8n Cutover Contract

## Status

READY FOR RUNTIME PARITY VALIDATION

This document defines the exact adapter change after the PostgreSQL functions in `db/domain/BE-DOM-001/001_finance_read_models.sql` have been installed and verified.

The purpose is to remove finance calculations from n8n without changing the current MiniApp HTTP response contract.

## Preconditions

Do not cut over n8n until all of the following are true:

- `moneytrack.finance_fx_convert_usd_bridge_v1(...)` exists;
- `moneytrack.finance_accounts_read_model_v1(...)` exists;
- `moneytrack.finance_dashboard_read_model_v1(...)` exists;
- `002_verify_finance_read_models.sql` reports parity for representative users;
- current MiniApp API responses have been captured for comparison;
- a rollback copy/export of the active n8n workflow exists.

## Adapter rule

n8n may resolve a Telegram caller to an internal MoneyTrack user id.

It must not calculate:

- balances;
- FX values;
- monthly income/expense/result;
- net worth;
- default-account financial values.

The extracted PostgreSQL functions accept internal `user_id` deliberately. Telegram identity is not part of the finance-domain contract.

## `Get Dashboard` node replacement

Replace the current multi-CTE finance query in node `Get Dashboard` with a thin adapter query:

```sql
with caller as (
    select u.id::bigint as user_id
    from moneytrack.app_users u
    where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
    limit 1
)
select rm.*
from caller c
cross join lateral moneytrack.finance_dashboard_read_model_v1(
    c.user_id,
    current_date
) rm;
```

`current_date` is supplied by the adapter as the explicit valuation date. The finance function itself has no hidden dependency on the wall-clock date.

### Response formatter

The existing `Format Dashboard Response` node can remain unchanged during the first cutover because the extracted function preserves its input row fields:

```text
user_id
base_currency
report_currency
language_code
date_from
date_to
net_worth
income_month
expenses_month
result_month
balances_by_currency
latest_operations
```

The public response remains:

```json
{
  "data": {
    "period": {
      "date_from": "...",
      "date_to": "..."
    },
    "summary": {
      "net_worth": 0,
      "income_month": 0,
      "expenses_month": 0,
      "result_month": 0,
      "currency": "EUR"
    },
    "balances_by_currency": [],
    "latest_operations": []
  }
}
```

No MiniApp change is required for this cutover.

## `Get Accounts` node replacement

Replace the current account-balance CTE query in the accounts node with:

```sql
with caller as (
    select u.id::bigint as user_id
    from moneytrack.app_users u
    where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
    limit 1
)
select rm.*
from caller c
cross join lateral moneytrack.finance_accounts_read_model_v1(
    c.user_id
) rm;
```

### Response formatter

The current account formatter may remain during this phase. It is allowed to:

- coerce PostgreSQL numeric values to JSON numbers;
- turn the flat account list into a display tree;
- wrap the row in the existing HTTP response envelope.

It must not recompute financial amounts or apply FX rules.

The extracted row contract remains:

```text
user_id
base_currency
total_base
default_account
accounts
```

## Error behavior

For an unknown Telegram user, the `caller` CTE produces no row and therefore the read-model call produces no row. Existing formatter behavior for an empty/no-user result should be retained during the compatibility cutover.

Do not move `USER_NOT_FOUND` into the finance-domain functions. Caller identity is an adapter/application concern, not a finance invariant.

## Shadow verification before switch

For representative users, run both implementations against the same database snapshot/date:

```text
legacy dashboard SQL
vs
finance_dashboard_read_model_v1(user_id, as_of)

legacy accounts SQL
vs
finance_accounts_read_model_v1(user_id)
```

Verify at minimum:

- period dates;
- report currency;
- income month;
- expense month;
- result month;
- net worth;
- balances by currency;
- latest 10 operations and order;
- every active account balance_original;
- every active account balance_base;
- total_base;
- default account.

Numeric comparison should initially be exact because the extracted formulas preserve operation ordering and PostgreSQL numeric arithmetic. If actual column types are floating-point, define an explicit tolerance before accepting parity; do not introduce an arbitrary tolerance silently.

## HTTP contract verification

After switching the two n8n queries, compare old/new API payloads after normalizing only fields known to be transport-volatile.

For dashboard, structural parity is required for:

```text
data.period
data.summary
data.balances_by_currency
data.latest_operations
```

For accounts, structural parity is required for:

```text
data.base_currency
data.total_base
data.default_account
data.accounts
```

## Rollback

Rollback the adapter first, not the database functions.

If parity fails after n8n cutover:

1. restore the previous n8n query for the affected node;
2. republish/restart n8n according to the existing deployment procedure;
3. keep the extracted functions installed for diagnosis;
4. compare the exact mismatching user/date against the verification SQL;
5. only drop the functions if they are proven unsafe or conflict with deployment.

This avoids destroying evidence during rollback.

## Post-cutover cleanup

Only after runtime/API parity is proven:

- remove the embedded dashboard financial CTEs from the workflow;
- remove the embedded account-balance financial CTEs from the workflow;
- retain only caller resolution + function call + response mapping;
- update the forensic inventory to mark D-001 mitigated for these two reads;
- begin write-path inventory for transaction posting and transfer semantics.

## Gate

The read-only extraction gate is:

```text
CODED
→ DB INSTALL VERIFIED
→ SQL PARITY PASS
→ N8N SHADOW PASS
→ API CONTRACT PASS
→ LEGACY QUERY REMOVED
```

At repository-only stage, the gate must not be reported as complete before the runtime verification steps have actually occurred.