# MoneyTrack — BE-DOM-001 — Runtime Gate

## Status

**HOLD — RUNTIME VALIDATION REQUIRED**

This document is the executable handoff between repository preparation and the
runtime cutover of the first BE-DOM-001 read-only vertical slice.

The repository-side implementation is not sufficient evidence for merge. The
PostgreSQL functions must be installed and verified against representative
existing MoneyTrack data before the active n8n workflow is changed.

## Preconditions

Run from a checkout of:

```text
feat/be-dom-001-finance-domain-extraction
```

Required local tools:

```text
psql
jq
```

Required runtime inputs:

```text
DATABASE_URL   PostgreSQL connection string; never commit it
USER_ID        internal moneytrack.app_users.id used for parity verification
AS_OF          fixed YYYY-MM-DD verification date
```

Use a representative user that has, where possible:

- more than one account;
- more than one currency;
- income and expense transactions in the selected month;
- historical FX rates;
- a configured base-currency default account.

## Gate 1 — Preflight

```bash
git status --short
git branch --show-current

command -v psql
command -v jq
```

Expected:

```text
clean worktree
feat/be-dom-001-finance-domain-extraction
psql present
jq present
```

Do not continue from a dirty worktree unless the unrelated changes have been
explicitly isolated.

## Gate 2 — Install PostgreSQL entry points

The install is a schema mutation and therefore requires an explicit opt-in:

```bash
export DATABASE_URL='postgresql://...'
export ALLOW_DB_MUTATION=1

scripts/be-dom-001-runtime.sh install
```

The installer creates/replaces only the BE-DOM-001 PostgreSQL functions defined
in:

```text
db/domain/BE-DOM-001/001_finance_read_models.sql
```

It does not modify transaction data and does not modify n8n.

### Immediate install checks

```sql
select
    to_regprocedure('moneytrack.finance_fx_convert_usd_bridge_v1(numeric,text,text,date)'),
    to_regprocedure('moneytrack.finance_accounts_read_model_v1(bigint)'),
    to_regprocedure('moneytrack.finance_dashboard_read_model_v1(bigint,date)');
```

All three entries must be non-null.

## Gate 3 — Diagnostic + hard parity verification

Set a fixed internal user and fixed as-of date:

```bash
export USER_ID='<internal app_users.id>'
export AS_OF='2026-08-08'

scripts/be-dom-001-runtime.sh verify
```

The runner performs two layers:

1. `002_verify_finance_read_models.sql` — human-readable diagnostics.
2. `003_assert_finance_read_models.sql` — machine-enforced hard assertions.

Expected final line:

```text
BE-DOM-001 parity gate PASS.
```

Any psql error, missing function, false FX parity, accounts mismatch or dashboard
mismatch is a **STOP**. Do not generate/import/publish the cutover workflow after
a failed parity gate.

## Gate 4 — Generate candidate n8n workflow

Only after Gate 3 passes:

```bash
scripts/be-dom-001-cutover-workflow.sh \
  workflows/moneytrack-miniapp-api-7TJ2xQTxLsTydXZc.json \
  /tmp/moneytrack-miniapp-api-be-dom-001.json
```

The transformer:

- never modifies the source workflow in place;
- requires exactly one `Get Dashboard` node;
- requires exactly one `Get Accounts` node;
- replaces only those two SQL queries;
- keeps the existing formatters and route/response nodes;
- asserts that known legacy finance-formula markers are absent afterwards.

## Gate 5 — Candidate workflow diff

Before any n8n import, verify that the semantic diff is restricted to the two
PostgreSQL node queries.

A convenient normalized comparison is:

```bash
jq -S . workflows/moneytrack-miniapp-api-7TJ2xQTxLsTydXZc.json \
  > /tmp/be-dom-001-before.json

jq -S . /tmp/moneytrack-miniapp-api-be-dom-001.json \
  > /tmp/be-dom-001-after.json

diff -u /tmp/be-dom-001-before.json /tmp/be-dom-001-after.json
```

Expected semantic changes:

```text
Get Dashboard.parameters.query
Get Accounts.parameters.query
```

Unexpected node, credential, webhook, formatter, connection, workflow setting or
metadata changes are a **STOP** until explained.

## Gate 6 — n8n shadow/import validation

Use the existing project deployment method for n8n workflow import. Do not
invent a second workflow ID or overwrite unrelated workflows.

Before publishing, preserve a runtime export/backup of the currently active
workflow.

After import but before treating the migration as complete, validate at least:

```text
GET /api/v1/dashboard
GET /api/v1/accounts
```

with a valid Telegram MiniApp identity.

Required compatibility points:

### Dashboard

```text
period.date_from
period.date_to
summary.net_worth
summary.income_month
summary.expenses_month
summary.result_month
summary.currency
balances_by_currency
latest_operations
```

### Accounts

```text
base_currency
total_base
default_account
accounts hierarchy produced by the existing formatter
```

The public API route and response contract must remain unchanged.

## Gate 7 — Runtime comparison

Compare pre-cutover and post-cutover responses for the same authenticated user
and the same persisted database state.

For monetary numeric values compare numerical meaning, not JSON formatting alone.
For JSON arrays whose ordering is part of the current UI contract, ordering must
also match.

Any unexplained difference is a **STOP** and triggers rollback of the n8n
workflow to the preserved runtime export.

## Rollback

### n8n rollback

Restore/import the preserved pre-cutover workflow export and publish it using the
existing deployment procedure.

### PostgreSQL rollback

Only after n8n no longer calls the BE-DOM-001 functions:

```bash
export ALLOW_DB_MUTATION=1
scripts/be-dom-001-runtime.sh rollback
```

Never drop the functions while an active workflow still depends on them.

## Completion gate

BE-DOM-001 first read-only vertical slice reaches **PASS** only when all are true:

```text
[ ] PostgreSQL functions installed successfully
[ ] diagnostic parity inspected
[ ] hard parity assertions PASS
[ ] candidate n8n workflow contains only intended SQL cutover
[ ] runtime backup captured before publish
[ ] dashboard API contract verified after cutover
[ ] accounts API contract verified after cutover
[ ] representative monetary values match pre-cutover behavior
[ ] legacy embedded finance SQL is no longer the active implementation
[ ] rollback path has been preserved
```

Until then:

```text
Gate: HOLD — RUNTIME VALIDATION REQUIRED
Merge: DO NOT MERGE
```

## Explicitly deferred finance-semantic debt

This slice preserves rather than fixes legacy behavior, including:

- dashboard FX valuation via the existing USD bridge formula;
- accounts use of persisted `amount_base` while dashboard performs rate-based
  valuation;
- missing FX potentially collapsing to zero through existing aggregate/adapter
  behavior;
- net-worth aggregation not filtering future-dated transactions.

These require separate finance-domain decisions after extraction. They must not
be silently changed during BE-DOM-001 parity migration.
