#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

MIGRATION="$ROOT/db/domain/UX-022/065_all_operations_turnover.sql"
WORK="$(mktemp -d /tmp/ux022r3-all-operations-gate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 all-operation turnover'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"

bash -n "$ROOT/scripts/ux022r3-all-operations-turnover-gate.sh"
[[ -f "$MIGRATION" ]]
python3 - "$MIGRATION" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
required=(
    'period_transfer_sides as',
    "'incoming'::text as transfer_direction",
    "'outgoing'::text as transfer_direction",
    'transfer_period_summary as',
    's.income_original + ts.income_original',
    's.expense_original + ts.expense_original',
    'transfer_base',
)
for token in required:
    assert token in s, token
assert s.rstrip().endswith('commit;')
print('source_contract=PASS')
PY

python3 - "$MIGRATION" "$WORK/candidate.sql" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
pos=src.lower().rfind('\ncommit;')
if pos < 0:
    raise SystemExit('final_commit_missing')
src=src[:pos] + '''

-- Runtime reconciliation check for the account shown in acceptance evidence.
do $validate$
declare
    v_account_id bigint;
    r record;
    v_income numeric;
    v_expense numeric;
begin
    select a.id into v_account_id
    from moneytrack.accounts a
    join moneytrack.app_users u on u.id = a.user_id
    where u.telegram_user_id = 294564730
      and a.name = 'Bank EUR'
      and upper(a.currency_code) = 'EUR'
      and coalesce(a.is_active, true) = true
    order by a.id
    limit 1;

    if v_account_id is null then
        raise exception 'BANK_EUR_ACCEPTANCE_ACCOUNT_NOT_FOUND';
    end if;

    select * into r
    from moneytrack.api_transactions_read_model_v2(
        294564730,
        v_account_id,
        date '2026-08-01',
        date '2026-08-31',
        false,
        array[v_account_id]::bigint[],
        null,
        null
    );

    select
        coalesce(sum(case
            when item->>'transaction_type' = 'income' then abs((item->>'amount_original')::numeric)
            when item->>'transaction_type' = 'transfer' and item->>'transfer_direction' = 'incoming' then abs((item->>'amount_original')::numeric)
            else 0 end), 0),
        coalesce(sum(case
            when item->>'transaction_type' in ('expense','adjustment') then abs((item->>'amount_original')::numeric)
            when item->>'transaction_type' = 'transfer' and item->>'transfer_direction' = 'outgoing' then abs((item->>'amount_original')::numeric)
            else 0 end), 0)
    into v_income, v_expense
    from jsonb_array_elements(coalesce(r.transactions, '[]'::jsonb)) item;

    if r.income is distinct from v_income then
        raise exception 'ALL_OPERATIONS_INCOME_MISMATCH api=% visible=%', r.income, v_income;
    end if;
    if r.expense is distinct from v_expense then
        raise exception 'ALL_OPERATIONS_EXPENSE_MISMATCH api=% visible=%', r.expense, v_expense;
    end if;
    if r.result is distinct from (v_income - v_expense) then
        raise exception 'ALL_OPERATIONS_RESULT_MISMATCH api=% visible=%', r.result, v_income - v_expense;
    end if;
end;
$validate$;

rollback;
'''
Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY

ux022_db_psql_file "$WORK/candidate.sql" >/dev/null
echo 'candidate_runtime_reconciliation=PASS'

cat > "$WORK/current.sql" <<'SQL'
\pset tuples_only on
\pset format unaligned
select
  'current_bank_eur=' ||
  coalesce(r.income::text,'NULL') || '/' ||
  coalesce(r.expense::text,'NULL') || '/' ||
  coalesce(r.result::text,'NULL') || '/transfers=' ||
  coalesce(r.transfers::text,'NULL')
from moneytrack.accounts a
join moneytrack.app_users u on u.id=a.user_id
cross join lateral moneytrack.api_transactions_read_model_v2(
  u.telegram_user_id,
  a.id,
  date '2026-08-01',
  date '2026-08-31',
  false,
  array[a.id]::bigint[],
  null,
  null
) r
where u.telegram_user_id=294564730
  and a.name='Bank EUR'
  and upper(a.currency_code)='EUR'
  and coalesce(a.is_active,true)=true
order by a.id
limit 1;
SQL
ux022_db_psql_file "$WORK/current.sql" | grep '^current_bank_eur=' || true

echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_ALL_OPERATIONS_TURNOVER_GATE=PASS'
