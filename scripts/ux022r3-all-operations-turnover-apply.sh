#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

MIGRATION="$ROOT/db/domain/UX-022/065_all_operations_turnover.sql"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/var/backups/moneytrack/ux022r3-all-operations/$STAMP"
WORK="$(mktemp -d /tmp/ux022r3-all-operations-apply.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 all-operation turnover controlled apply'
echo '# Gate'
echo 'MUTATING_AFTER_INTERNAL_PREFLIGHT'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"

bash "$ROOT/scripts/ux022r3-all-operations-turnover-gate.sh"
echo 'internal_preflight=PASS'

mkdir -p "$BACKUP_DIR"
cat > "$WORK/backup.sql" <<'SQL'
\pset tuples_only on
\pset format unaligned
select pg_get_functiondef('moneytrack.api_accounts_explorer_summary_read_model_v2(bigint,bigint[],bigint[],bigint[],date,date,date)'::regprocedure);
select '';
select pg_get_functiondef('moneytrack.api_transactions_read_model_v2(bigint,bigint,date,date,boolean,bigint[],bigint[],bigint[])'::regprocedure);
SQL
ux022_db_psql_file "$WORK/backup.sql" > "$BACKUP_DIR/read_models.before.sql"
[[ -s "$BACKUP_DIR/read_models.before.sql" ]]
echo "runtime_backup=PASS path=$BACKUP_DIR"

ux022_db_psql_file "$MIGRATION" >/dev/null
echo 'db_apply=PASS'

cat > "$WORK/postcheck.sql" <<'SQL'
\pset tuples_only on
\pset format unaligned
with target as (
  select a.id as account_id, u.telegram_user_id
  from moneytrack.accounts a
  join moneytrack.app_users u on u.id=a.user_id
  where u.telegram_user_id=294564730
    and a.name='Bank EUR'
    and upper(a.currency_code)='EUR'
    and coalesce(a.is_active,true)=true
  order by a.id
  limit 1
), r as (
  select x.*
  from target t
  cross join lateral moneytrack.api_transactions_read_model_v2(
    t.telegram_user_id,
    t.account_id,
    date '2026-08-01',
    date '2026-08-31',
    false,
    array[t.account_id]::bigint[],
    null,
    null
  ) x
), visible as (
  select
    coalesce(sum(case
      when item->>'transaction_type'='income' then abs((item->>'amount_original')::numeric)
      when item->>'transaction_type'='transfer' and item->>'transfer_direction'='incoming' then abs((item->>'amount_original')::numeric)
      else 0 end),0)::numeric as income,
    coalesce(sum(case
      when item->>'transaction_type' in ('expense','adjustment') then abs((item->>'amount_original')::numeric)
      when item->>'transaction_type'='transfer' and item->>'transfer_direction'='outgoing' then abs((item->>'amount_original')::numeric)
      else 0 end),0)::numeric as expense
  from r, lateral jsonb_array_elements(coalesce(r.transactions,'[]'::jsonb)) item
)
select case
  when r.income is not distinct from v.income
   and r.expense is not distinct from v.expense
   and r.result is not distinct from (v.income-v.expense)
  then 'postcheck_reconciliation=PASS'
  else 'postcheck_reconciliation=FAIL api=' || r.income || '/' || r.expense || '/' || r.result || ' visible=' || v.income || '/' || v.expense || '/' || (v.income-v.expense)
end
from r cross join visible v;

with target as (
  select a.id as account_id, u.telegram_user_id
  from moneytrack.accounts a
  join moneytrack.app_users u on u.id=a.user_id
  where u.telegram_user_id=294564730
    and a.name='Bank EUR'
    and upper(a.currency_code)='EUR'
    and coalesce(a.is_active,true)=true
  order by a.id
  limit 1
)
select 'bank_eur_after=' || r.income || '/' || r.expense || '/' || r.result || '/transfers=' || r.transfers
from target t
cross join lateral moneytrack.api_transactions_read_model_v2(
  t.telegram_user_id,
  t.account_id,
  date '2026-08-01',
  date '2026-08-31',
  false,
  array[t.account_id]::bigint[],
  null,
  null
) r;
SQL
POSTCHECK="$(ux022_db_psql_file "$WORK/postcheck.sql" | tr -d '\r')"
printf '%s\n' "$POSTCHECK"
grep -q '^postcheck_reconciliation=PASS$' <<<"$POSTCHECK"

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=read_models_only'
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'UX022R3_ALL_OPERATIONS_TURNOVER_APPLY=PASS'
