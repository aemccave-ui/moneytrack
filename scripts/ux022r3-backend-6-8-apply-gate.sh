#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
QUICK_ID="UX022QuickInput202608"
TEXT_ID="f5ioJKyPTupUMV9h"
PHOTO_ID="5VC0EcFB21rwTfoI"
CATEGORY_ID="UX022CategorySettings202608"
WORK="$(mktemp -d /tmp/ux022r3-backend-6-8-gate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for command_name in docker python3; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "runtime_preflight=FAIL missing_command=$command_name" >&2; exit 1; }
done
docker inspect "$N8N_CONTAINER" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

echo '# Phase'
echo 'UX-022R3 backend 6-8 controlled apply dry-run'
echo '# Gate'
echo 'READ_ONLY / APPLY_CANDIDATE'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'clean_checkout=PASS'

bash "$ROOT/scripts/ux022-source-gate.sh"
python3 "$ROOT/scripts/ux022r3-verify-backend-6-8-apply-source.py"
echo 'source_preflight=PASS'

export_one() {
  local id="$1" target="$2" remote="/tmp/ux022r3-b68-gate-$$-$id.json"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  test -s "$target"
}

export_one "$QUICK_ID" "$WORK/quick.before.json"
export_one "$TEXT_ID" "$WORK/text.before.json"
export_one "$PHOTO_ID" "$WORK/photo.before.json"

docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-b68-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-b68-all.json" "$WORK/all.before.json" >/dev/null
docker exec -u 0 "$N8N_CONTAINER" rm -f /tmp/ux022r3-b68-all.json >/dev/null 2>&1 || true

echo 'runtime_exports=PASS'

python3 "$ROOT/scripts/ux022r3-patch-quick-ingress-time.py" "$WORK/quick.before.json" "$WORK/quick.candidate.json"
python3 "$ROOT/scripts/be-dom-001-transform-text-write.py" "$WORK/text.before.json" "$WORK/text.candidate.json"
python3 "$ROOT/scripts/ux022r3-patch-photo-receipt-clock.py" "$WORK/photo.before.json" "$WORK/photo.clock.json"
python3 "$ROOT/scripts/ux022r3-patch-receipt-operation-metadata.py" "$WORK/photo.clock.json" "$WORK/photo.candidate.json"
python3 "$ROOT/scripts/ux022r3-generate-category-settings-workflow.py" --output "$WORK/category.candidate.json"
echo 'runtime_candidates_generated=PASS'

python3 - "$WORK/quick.before.json" "$WORK/quick.candidate.json" "$WORK/text.before.json" "$WORK/text.candidate.json" "$WORK/photo.before.json" "$WORK/photo.candidate.json" "$WORK/category.candidate.json" "$WORK/all.before.json" <<'PY'
import hashlib,json,sys
from pathlib import Path


def one(path):
    raw=json.loads(Path(path).read_text(encoding='utf-8'))
    if isinstance(raw,list):
        assert len(raw)==1,(path,len(raw))
        return raw[0]
    return raw


def digest(value):
    return hashlib.sha256(json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def changed_nodes(before, after):
    a={n.get('name'):n for n in before.get('nodes',[])}
    b={n.get('name'):n for n in after.get('nodes',[])}
    assert a.keys()==b.keys()
    return {name for name in a if digest(a[name])!=digest(b[name])}

q0,q1,t0,t1,p0,p1,cat=map(one,sys.argv[1:8])
all_raw=json.loads(Path(sys.argv[8]).read_text(encoding='utf-8'))
all_workflows=all_raw if isinstance(all_raw,list) else [all_raw]

assert str(q0.get('id'))=='UX022QuickInput202608'
assert str(t0.get('id'))=='f5ioJKyPTupUMV9h'
assert str(p0.get('id'))=='5VC0EcFB21rwTfoI'
for before,after in ((q0,q1),(t0,t1),(p0,p1)):
    assert str(before.get('id'))==str(after.get('id'))
    assert digest(before.get('connections') or {})==digest(after.get('connections') or {})

qc=changed_nodes(q0,q1)
assert qc <= {'Voice To Text'} and "$('Voice Prepare').first().json.message_date" in json.dumps(q1,ensure_ascii=False),qc
print('quick_candidate_isolation=PASS changed=' + ','.join(sorted(qc or {'NONE'})))

tc=changed_nodes(t0,t1)
assert {'Insert transaction text','Insert adjustment transaction'} <= tc <= {'Insert transaction text','Insert adjustment transaction','Insert opening balance'},tc
assert 'message_date' in json.dumps(t1,ensure_ascii=False)
print('text_candidate_isolation=PASS changed=' + ','.join(sorted(tc)))

pc=changed_nodes(p0,p1)
assert pc == {'Analyze image','Parse receipt JSON','Update product category'},pc
blob=json.dumps(p1,ensure_ascii=False)
assert 'receipt_time' in blob
assert 'receipt_finalize_transaction_metadata_v1' in blob
print('photo_candidate_isolation=PASS changed=' + ','.join(sorted(pc)))

assert str(cat.get('id'))=='UX022CategorySettings202608'
assert cat.get('active') is False
assert 'api/v1/categories' in json.dumps(cat,ensure_ascii=False)
assert 'UX022CategorySettings202608' not in {str(w.get('id')) for w in all_workflows}
print('category_settings_candidate_new_id=PASS')
print('workflow_candidate_gate=PASS')
PY

cat > "$WORK/db-preflight.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

do $$
begin
  if exists (
      select 1 from information_schema.columns
      where table_schema='moneytrack' and table_name='category_catalog' and column_name='flow_type'
  ) then
      raise exception 'UX022R3_FLOW_TYPE_ALREADY_PRESENT';
  end if;
  if to_regprocedure('moneytrack.category_update_v1(bigint,bigint,text,text)') is not null then
      raise exception 'UX022R3_CATEGORY_UPDATE_ALREADY_PRESENT';
  end if;
  if to_regprocedure('moneytrack.receipt_finalize_transaction_metadata_v1(bigint,bigint,text,bigint)') is not null then
      raise exception 'UX022R3_RECEIPT_FINALIZER_ALREADY_PRESENT';
  end if;
end $$;

with usage as (
  select c.id,c.user_id,c.code,
         count(t.id) filter (where t.transaction_type='income')::bigint as income_count,
         count(t.id) filter (where t.transaction_type in ('expense','adjustment'))::bigint as expense_count
  from moneytrack.category_catalog c
  left join moneytrack.transactions t on t.category_id=c.id
  where coalesce(c.is_active,true)=true
  group by c.id,c.user_id,c.code
), predicted as (
  select *, case
    when code in ('transfer','uncategorized') then null
    when income_count>0 and expense_count=0 then 'income'
    when expense_count>0 and income_count=0 then 'expense'
    when code='income' or code like 'income.%' then 'income'
    when code in (
      'food','food.groceries','food.vegetables','food.fruits','food.bakery','food.dairy','food.meat','food.fish','food.drinks',
      'transport','home','health','entertainment','finance','finance.fees',
      'legal','life','other','required'
    ) then 'expense'
    when code like 'legal.%' or code like 'life.%' or code like 'other.%' or code like 'required.%' then 'expense'
    else null
  end as predicted_flow
  from usage
)
select 'category_predicted_unresolved=' || count(*)
from predicted
where user_id<>0
  and code not in ('transfer','uncategorized')
  and predicted_flow is null;

select 'special_category_transaction_usage=' || count(*)
from moneytrack.transactions t
join moneytrack.category_catalog c on c.id=t.category_id
where c.code in ('transfer','uncategorized');

select 'special_category_active_rows=' || count(*)
from moneytrack.category_catalog c
where c.code in ('transfer','uncategorized') and coalesce(c.is_active,true)=true;
SQL

DB_REPORT="$(ux022_db_psql_file "$WORK/db-preflight.sql")"
printf '%s\n' "$DB_REPORT"
grep -qx 'category_predicted_unresolved=0' <<<"$DB_REPORT"
grep -qx 'special_category_transaction_usage=0' <<<"$DB_REPORT"
echo 'db_semantic_preflight=PASS'

echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_BACKEND_6_8_APPLY_GATE=PASS'
