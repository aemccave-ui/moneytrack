#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
PHOTO_ID="5VC0EcFB21rwTfoI"
WORK="$(mktemp -d /tmp/ux022r3-backend-6-8-deep.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for command_name in docker python3 grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "runtime_preflight=FAIL missing_command=$command_name" >&2
    exit 1
  }
done
docker inspect "$N8N_CONTAINER" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

echo '# Phase'
echo 'UX-022R3 backend 6-8 deep forensic'
echo '# Gate'
echo 'READ_ONLY / PHOTO_SCHEMA_AND_CATEGORY_TEMPLATE'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'clean_checkout=PASS'

PHOTO_REMOTE="/tmp/ux022r3-b68-deep-$$-photo.json"
docker exec -u 0 "$N8N_CONTAINER" rm -f "$PHOTO_REMOTE" >/dev/null 2>&1 || true
docker exec "$N8N_CONTAINER" n8n export:workflow --id="$PHOTO_ID" --output="$PHOTO_REMOTE" >/dev/null
docker cp "$N8N_CONTAINER:$PHOTO_REMOTE" "$WORK/photo.json" >/dev/null
docker exec -u 0 "$N8N_CONTAINER" rm -f "$PHOTO_REMOTE" >/dev/null 2>&1 || true
test -s "$WORK/photo.json"
echo 'photo_runtime_export=PASS'

python3 - "$WORK/photo.json" <<'PY'
import hashlib
import json
import re
import sys
from collections import deque
from pathlib import Path

raw = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if isinstance(raw, list):
    assert len(raw) == 1, f'photo_workflow_count={len(raw)}'
    wf = raw[0]
else:
    wf = raw

assert str(wf.get('id')) == '5VC0EcFB21rwTfoI', wf.get('id')
nodes = wf.get('nodes') or []
node_map = {str(n.get('name') or ''): n for n in nodes}
parse_rows = [n for n in nodes if str(n.get('name') or '') == 'Parse receipt JSON']
assert len(parse_rows) == 1, f'parse_receipt_json_count={len(parse_rows)}'
parse_name = 'Parse receipt JSON'

reverse = {}
forward = {}
for source, outputs in (wf.get('connections') or {}).items():
    for channel in (outputs or {}).values():
        for branch in channel or []:
            for edge in branch or []:
                target = str(edge.get('node') or '')
                if not target:
                    continue
                reverse.setdefault(target, set()).add(str(source))
                forward.setdefault(str(source), set()).add(target)

print('photo_workflow_id=' + str(wf.get('id')))
print('photo_workflow_name=' + str(wf.get('name')))
print('photo_workflow_active=' + str(wf.get('active')))
print('photo_workflow_versionId=' + str(wf.get('versionId') or ''))
print('photo_workflow_activeVersionId=' + str(wf.get('activeVersionId') or ''))
print('photo_workflow_nodes=' + str(len(nodes)))
print('parse_receipt_json_type=' + str(parse_rows[0].get('type')))
print('parse_receipt_json_predecessors=' + ','.join(sorted(reverse.get(parse_name, set()))) )
print('parse_receipt_json_successors=' + ','.join(sorted(forward.get(parse_name, set()))) )

# Collect the Parse receipt JSON neighborhood so the next patch can target the
# actual active AI/parser contract rather than guessing a node type or prompt.
seen = {parse_name}
queue = deque([(parse_name, 0)])
while queue:
    name, depth = queue.popleft()
    if depth >= 3:
        continue
    for other in sorted(reverse.get(name, set()) | forward.get(name, set())):
        if other not in seen:
            seen.add(other)
            queue.append((other, depth + 1))

for name in sorted(seen):
    n = node_map.get(name) or {}
    print('photo_neighborhood_node=' + json.dumps({
        'name': name,
        'type': n.get('type'),
        'typeVersion': n.get('typeVersion'),
        'disabled': n.get('disabled', False),
    }, ensure_ascii=False, separators=(',', ':')))


def walk(value, path=''):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f'{path}.{key}' if path else str(key)
            yield from walk(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, f'{path}[{index}]')
    elif isinstance(value, str):
        yield path, value

# Print only strings that reveal the receipt extraction/output contract. This
# deliberately avoids credentials and unrelated workflow configuration.
contract_pattern = re.compile(
    r'receipt_date|receipt_time|receipt_datetime|shop_name|total_amount|currency|items|item_name_original|json|schema|structured|prompt|vision',
    re.I,
)
explicit_clock_pattern = re.compile(r'receipt_time|receipt_datetime|["\']time["\']\s*[:=]|\.time\b', re.I)
receipt_date_hits = 0
explicit_clock_hits = 0
reported = 0
for n in nodes:
    params = n.get('parameters') or {}
    for path, value in walk(params):
        if 'receipt_date' in value.lower():
            receipt_date_hits += 1
        if explicit_clock_pattern.search(value):
            explicit_clock_hits += 1
        if not contract_pattern.search(value):
            continue
        # Keep the report bounded while preserving enough source to build an
        # exact deterministic transformer on the next step.
        rendered = value
        truncated = False
        if len(rendered) > 12000:
            rendered = rendered[:12000]
            truncated = True
        payload = {
            'node': n.get('name'),
            'type': n.get('type'),
            'path': path,
            'sha256': hashlib.sha256(value.encode()).hexdigest(),
            'length': len(value),
            'truncated': truncated,
            'value': rendered,
        }
        print('photo_contract_parameter=' + json.dumps(payload, ensure_ascii=False, separators=(',', ':')))
        reported += 1

print(f'photo_receipt_date_parameter_hits={receipt_date_hits}')
print(f'photo_explicit_clock_parameter_hits={explicit_clock_hits}')
print(f'photo_contract_parameters_reported={reported}')
print('photo_schema_deep_inspection=PASS')
PY

cat > "$WORK/category-template.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

select '# Category template tree';
select format(
    'template_category id=%s code=%s parent=%s active=%s sort=%s translations=%s',
    c.id,
    c.code,
    coalesce(p.code, 'ROOT'),
    coalesce(c.is_active, true),
    coalesce(c.sort_order, 0),
    coalesce((
        select jsonb_object_agg(tr.language_code, tr.name order by tr.language_code)
        from moneytrack.category_catalog_translations tr
        where tr.category_id = c.id
    ), '{}'::jsonb)::text
)
from moneytrack.category_catalog c
left join moneytrack.category_catalog p on p.id = c.parent_id
where c.user_id = 0
order by coalesce(c.sort_order, 0), c.code;

select '# Category code usage across user-owned catalogs';
with usage as (
    select
        c.id,
        c.user_id,
        c.code,
        p.code as parent_code,
        coalesce(nullif(to_jsonb(c)->>'flow_type',''),'') as current_flow,
        count(t.id) filter (where t.transaction_type='income')::bigint as income_count,
        count(t.id) filter (where t.transaction_type in ('expense','adjustment'))::bigint as expense_count
    from moneytrack.category_catalog c
    left join moneytrack.category_catalog p on p.id = c.parent_id
    left join moneytrack.transactions t on t.category_id = c.id
    where c.user_id <> 0
      and coalesce(c.is_active, true) = true
    group by c.id,c.user_id,c.code,p.code
), per_code as (
    select
        code,
        string_agg(distinct coalesce(parent_code,'ROOT'), ',' order by coalesce(parent_code,'ROOT')) as parents,
        count(distinct user_id)::bigint as user_count,
        sum(income_count)::bigint as income_count,
        sum(expense_count)::bigint as expense_count,
        count(*) filter (where current_flow='')::bigint as unset_count
    from usage
    group by code
)
select format(
    'category_code code=%s template=%s parents=%s users=%s income=%s expense=%s unset=%s observed=%s',
    pc.code,
    case when exists (select 1 from moneytrack.category_catalog tc where tc.user_id=0 and tc.code=pc.code) then 'YES' else 'NO' end,
    pc.parents,
    pc.user_count,
    pc.income_count,
    pc.expense_count,
    pc.unset_count,
    case
      when pc.income_count>0 and pc.expense_count=0 then 'INCOME'
      when pc.expense_count>0 and pc.income_count=0 then 'EXPENSE'
      when pc.income_count>0 and pc.expense_count>0 then 'MIXED'
      else 'UNUSED'
    end
)
from per_code pc
order by pc.code;

select '# Per-user category/transaction summary';
with category_counts as (
    select
        c.user_id,
        count(*) filter (where coalesce(c.is_active,true))::bigint as active_categories,
        count(*) filter (
            where coalesce(c.is_active,true)
              and nullif(coalesce(to_jsonb(c)->>'flow_type',''),'') is null
        )::bigint as unset_flow
    from moneytrack.category_catalog c
    where c.user_id <> 0
    group by c.user_id
), transaction_counts as (
    select
        t.user_id,
        count(*)::bigint as transactions,
        count(*) filter (where t.category_id is not null)::bigint as categorized_transactions,
        count(*) filter (where t.transaction_type='income')::bigint as income_transactions,
        count(*) filter (where t.transaction_type in ('expense','adjustment'))::bigint as expense_transactions
    from moneytrack.transactions t
    group by t.user_id
)
select format(
    'category_user user_id=%s active_categories=%s unset_flow=%s transactions=%s categorized=%s income_tx=%s expense_tx=%s',
    cc.user_id,
    cc.active_categories,
    cc.unset_flow,
    coalesce(tc.transactions,0),
    coalesce(tc.categorized_transactions,0),
    coalesce(tc.income_transactions,0),
    coalesce(tc.expense_transactions,0)
)
from category_counts cc
left join transaction_counts tc on tc.user_id=cc.user_id
order by cc.user_id;

select '# Unresolved user categories absent from template';
select format(
    'non_template_unresolved user_id=%s id=%s code=%s parent=%s translations=%s',
    c.user_id,
    c.id,
    c.code,
    coalesce(p.code,'ROOT'),
    coalesce((
        select jsonb_object_agg(tr.language_code, tr.name order by tr.language_code)
        from moneytrack.category_catalog_translations tr
        where tr.category_id = c.id
    ), '{}'::jsonb)::text
)
from moneytrack.category_catalog c
left join moneytrack.category_catalog p on p.id=c.parent_id
where c.user_id<>0
  and coalesce(c.is_active,true)=true
  and nullif(coalesce(to_jsonb(c)->>'flow_type',''),'') is null
  and not exists (
      select 1 from moneytrack.category_catalog tc
      where tc.user_id=0 and tc.code=c.code
  )
order by c.user_id,c.code;

select '# Special-code usage evidence';
select format(
    'special_code code=%s transaction_type=%s count=%s',
    c.code,
    t.transaction_type,
    count(*)
)
from moneytrack.category_catalog c
join moneytrack.transactions t on t.category_id=c.id
where c.code in ('transfer','uncategorized')
group by c.code,t.transaction_type
order by c.code,t.transaction_type;

select format(
    'transactions_without_category type=%s count=%s',
    t.transaction_type,
    count(*)
)
from moneytrack.transactions t
where t.category_id is null
group by t.transaction_type
order by t.transaction_type;
SQL

ux022_db_psql_file "$WORK/category-template.sql"
echo 'category_template_deep_inspection=PASS'

echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'BACKEND_6_8_DEEP_FORENSIC=PASS'
