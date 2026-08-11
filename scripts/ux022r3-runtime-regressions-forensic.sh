#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-runtime-regressions.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

container_tmp_rm() {
  local remote="$1"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-regression-$$-${id}.json"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  container_tmp_rm "$remote"
}

echo '# Phase'
echo 'UX-022R3 runtime regressions forensic: photo + balances + turnovers'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"

docker inspect "$N8N_CONTAINER" >/dev/null
export_one UX022QuickInput202608 "$WORK/quick.json"
export_one 5VC0EcFB21rwTfoI "$WORK/photo.json"

python3 - "$WORK/quick.json" "$WORK/photo.json" <<'PY'
import json,sys
from pathlib import Path

def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    return raw[0] if isinstance(raw,list) else raw

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    return rows[0] if len(rows)==1 else None

quick=one(sys.argv[1]); photo=one(sys.argv[2])
print(f"quick_active={str(quick.get('active')).upper()}")
print(f"photo_active={str(photo.get('active')).upper()}")
print(f"quick_published={'PASS' if quick.get('active') is True and quick.get('versionId')==quick.get('activeVersionId') else 'FAIL'}")
print(f"photo_published={'PASS' if photo.get('active') is True and photo.get('versionId')==photo.get('activeVersionId') else 'FAIL'}")

h=node(quick,'Photo Hash')
prep=node(quick,'Photo Prepare')
fmt=node(quick,'Photo Format')
quick_patched=bool(
    h and "createHash('sha256')" in (h.get('parameters',{}).get('jsCode') or '')
    and prep and "telegram_file_id: $('Photo Hash').first().json.photo_identity" in (prep.get('parameters',{}).get('jsCode') or '')
    and fmt and 'RECEIPT_DUPLICATE_EXACT' in (fmt.get('parameters',{}).get('jsCode') or '')
    and 'RECEIPT_DUPLICATE_SEMANTIC' in (fmt.get('parameters',{}).get('jsCode') or '')
)
print(f"quick_photo_dedup_contract={'PATCHED' if quick_patched else 'NOT_PATCHED_OR_UNKNOWN'}")

exact=node(photo,'Check duplicate receipt')
semantic=node(photo,'Check semantic duplicate receipt')
exact_q=(exact.get('parameters',{}).get('query') or '') if exact else ''
semantic_q=(semantic.get('parameters',{}).get('query') or '') if semantic else ''
photo_patched=bool(
    'r.user_id =' in exact_q.lower()
    and 'r.telegram_file_id' in exact_q.lower()
    and 'amount_signature' in semantic_q.lower()
)
print(f"photo_dedup_contract={'PATCHED' if photo_patched else 'NOT_PATCHED_OR_UNKNOWN'}")
if exact:
    print('--- exact_duplicate_query ---')
    print(exact_q)
if semantic:
    print('--- semantic_duplicate_query ---')
    print(semantic_q)
PY

echo '# n8n recent error log hints (read-only)'
docker logs --since 4h "$N8N_CONTAINER" 2>&1 \
  | grep -Ei 'error|receipt|duplicate|semantic|photo|postgres|invalid input|query' \
  | tail -n 180 \
  || true

cat > "$WORK/forensic.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset pager off
\pset format aligned

\echo '# Candidate users/accounts matching screenshot names'
select
    u.id as user_id,
    u.telegram_user_id,
    a.id as account_id,
    a.name,
    a.currency_code,
    a.parent_id,
    a.is_active
from moneytrack.accounts a
join moneytrack.app_users u on u.id = a.user_id
where lower(a.name) in ('bank eur','bank','freedom eur','freedom finance')
order by u.id, a.name, a.id;

\echo '# Dashboard vs canonical movement balance by user'
with users as (
    select distinct a.user_id
    from moneytrack.accounts a
    where lower(a.name) in ('bank eur','bank','freedom eur','freedom finance')
),
tx_movements as (
    select t.user_id, t.account_id,
           case
             when t.transaction_type in ('openingbalance','income') then t.amount_original
             when t.transaction_type = 'expense' then -abs(t.amount_original)
             when t.transaction_type = 'adjustment' then t.amount_original
             else 0
           end::numeric as amount
    from moneytrack.transactions t
    join users u on u.user_id=t.user_id
),
transfer_movements as (
    select tr.user_id, tr.from_account_id as account_id, -tr.from_amount::numeric as amount
    from moneytrack.transfers tr join users u on u.user_id=tr.user_id
    union all
    select tr.user_id, tr.to_account_id as account_id, tr.to_amount::numeric as amount
    from moneytrack.transfers tr join users u on u.user_id=tr.user_id
),
all_movements as (
    select * from tx_movements
    union all
    select * from transfer_movements
),
leaf_accounts as (
    select a.*
    from moneytrack.accounts a
    join users u on u.user_id=a.user_id
    where coalesce(a.is_active,true)=true
      and not exists (
        select 1 from moneytrack.accounts c
        where c.user_id=a.user_id and c.parent_id=a.id and coalesce(c.is_active,true)=true
      )
),
own_balances as (
    select a.user_id,a.id as account_id,a.name,a.currency_code,
           coalesce(sum(m.amount),0)::numeric as balance_original
    from leaf_accounts a
    left join all_movements m on m.user_id=a.user_id and m.account_id=a.id
    group by a.user_id,a.id,a.name,a.currency_code
),
converted as (
    select ob.*,
           moneytrack.finance_fx_convert_usd_bridge_v1(
             ob.balance_original,
             ob.currency_code,
             coalesce(s.report_currency,s.base_currency,au.default_currency,'EUR'),
             current_date
           ) as balance_report
    from own_balances ob
    join moneytrack.app_users au on au.id=ob.user_id
    left join moneytrack.user_settings s on s.user_id=ob.user_id
),
canonical as (
    select user_id,sum(balance_report)::numeric as transfer_inclusive_leaf_total
    from converted group by user_id
)
select
    u.user_id,
    au.telegram_user_id,
    d.net_worth as dashboard_net_worth,
    c.transfer_inclusive_leaf_total,
    d.net_worth-c.transfer_inclusive_leaf_total as dashboard_minus_canonical
from users u
join moneytrack.app_users au on au.id=u.user_id
cross join lateral moneytrack.finance_dashboard_read_model_v1(u.user_id,current_date) d
join canonical c on c.user_id=u.user_id
order by u.user_id;

\echo '# Bank EUR current balance decomposition'
with target as (
    select a.id,a.user_id,a.name,a.currency_code
    from moneytrack.accounts a
    where lower(a.name)='bank eur' and coalesce(a.is_active,true)=true
),
tx as (
    select t.user_id,t.account_id,
           sum(case
             when t.transaction_type in ('openingbalance','income') then t.amount_original
             when t.transaction_type='expense' then -abs(t.amount_original)
             when t.transaction_type='adjustment' then t.amount_original
             else 0
           end)::numeric as tx_balance
    from moneytrack.transactions t join target a on a.id=t.account_id and a.user_id=t.user_id
    group by t.user_id,t.account_id
),
tr as (
    select a.user_id,a.id as account_id,
           coalesce(sum(case when x.from_account_id=a.id then -x.from_amount else x.to_amount end),0)::numeric as transfer_net
    from target a
    left join moneytrack.transfers x
      on x.user_id=a.user_id and (x.from_account_id=a.id or x.to_account_id=a.id)
    group by a.user_id,a.id
)
select a.user_id,a.id as account_id,a.name,a.currency_code,
       coalesce(tx.tx_balance,0) as transaction_balance,
       tr.transfer_net,
       coalesce(tx.tx_balance,0)+tr.transfer_net as full_balance
from target a
left join tx on tx.user_id=a.user_id and tx.account_id=a.id
join tr on tr.user_id=a.user_id and tr.account_id=a.id
order by a.user_id,a.id;

\echo '# Bank EUR month transaction totals by type'
select
    t.user_id,t.account_id,t.transaction_type,
    count(*) as row_count,
    sum(abs(t.amount_original))::numeric as amount_abs
from moneytrack.transactions t
join moneytrack.accounts a on a.id=t.account_id and a.user_id=t.user_id
where lower(a.name)='bank eur'
  and t.transaction_date >= date_trunc('month',current_date)
  and t.transaction_date < current_date + 1
 group by t.user_id,t.account_id,t.transaction_type
 order by t.user_id,t.account_id,t.transaction_type;

\echo '# Bank EUR month transactions with receipt linkage'
select
    t.user_id,t.id as transaction_id,t.transaction_date,t.transaction_type,
    t.amount_original,t.currency_original,t.category_id,t.description,
    r.id as receipt_id,r.receipt_date,r.shop_name,r.total_amount,r.currency as receipt_currency,
    r.telegram_file_id,r.receipt_fingerprint
from moneytrack.transactions t
join moneytrack.accounts a on a.id=t.account_id and a.user_id=t.user_id
left join moneytrack.receipts r on r.transaction_id=t.id and r.user_id=t.user_id
where lower(a.name)='bank eur'
  and t.transaction_date >= date_trunc('month',current_date)
  and t.transaction_date < current_date + 1
order by t.user_id,t.transaction_date desc,t.id desc;

\echo '# Bank EUR month transfers'
select
    tr.user_id,tr.id as transfer_id,tr.transfer_date,
    tr.from_account_id,af.name as from_name,tr.from_amount,tr.from_currency,
    tr.to_account_id,at.name as to_name,tr.to_amount,tr.to_currency,tr.transfer_type
from moneytrack.transfers tr
join moneytrack.accounts af on af.id=tr.from_account_id and af.user_id=tr.user_id
join moneytrack.accounts at on at.id=tr.to_account_id and at.user_id=tr.user_id
where (lower(af.name)='bank eur' or lower(at.name)='bank eur')
  and tr.transfer_date >= date_trunc('month',current_date)
  and tr.transfer_date < current_date + 1
order by tr.user_id,tr.transfer_date desc,tr.id desc;

\echo '# Bank EUR API v2 turnover result for current month'
select
    u.telegram_user_id,
    a.id as account_id,
    a.name,
    rm.income,rm.expense,rm.result,rm.transfers,rm.count,rm.summary_currency
from moneytrack.accounts a
join moneytrack.app_users u on u.id=a.user_id
cross join lateral moneytrack.api_transactions_read_model_v2(
    u.telegram_user_id,
    a.id,
    date_trunc('month',current_date)::date,
    current_date,
    false,
    array[a.id]::bigint[],
    null,
    null
) rm
where lower(a.name)='bank eur' and coalesce(a.is_active,true)=true
order by a.user_id,a.id;

\echo '# Recent receipts and semantic duplicate candidates'
with receipt_sig as (
    select
      r.user_id,r.id,r.transaction_id,r.receipt_date,r.shop_name,r.total_amount,r.currency,
      r.telegram_file_id,r.receipt_fingerprint,r.created_at,
      count(ri.id)::int as item_count,
      coalesce(array_agg(round(ri.amount,2) order by round(ri.amount,2)) filter(where ri.id is not null),array[]::numeric[]) as amount_signature
    from moneytrack.receipts r
    left join moneytrack.receipt_items ri on ri.receipt_id=r.id
    where r.created_at >= now()-interval '14 days'
    group by r.user_id,r.id
)
select * from receipt_sig
order by user_id,created_at desc,id desc
limit 60;

\echo '# Existing semantic duplicates by date/total/currency/item signature'
with receipt_sig as (
    select
      r.user_id,r.id,r.receipt_date,r.total_amount,upper(r.currency) as currency,
      count(ri.id)::int as item_count,
      coalesce(array_agg(round(ri.amount,2) order by round(ri.amount,2)) filter(where ri.id is not null),array[]::numeric[]) as amount_signature
    from moneytrack.receipts r
    left join moneytrack.receipt_items ri on ri.receipt_id=r.id
    group by r.user_id,r.id
)
select user_id,receipt_date,total_amount,currency,item_count,amount_signature,
       count(*) as duplicate_count,array_agg(id order by id) as receipt_ids
from receipt_sig
group by user_id,receipt_date,total_amount,currency,item_count,amount_signature
having count(*)>1
order by duplicate_count desc,user_id,receipt_date desc;
SQL

ux022_db_psql_file "$WORK/forensic.sql"

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_RUNTIME_REGRESSIONS_FORENSIC=PASS'
