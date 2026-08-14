#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
QUICK_ID="UX022QuickInput202608"
TEXT_ID="f5ioJKyPTupUMV9h"
VOICE_ID="Td7kvvrtqQK0FTJg"
PHOTO_ID="5VC0EcFB21rwTfoI"
WORK="$(mktemp -d /tmp/ux022r3-backend-6-8-forensic.XXXXXX)"
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
echo 'UX-022R3 backend 6-8 runtime forensic'
echo '# Gate'
echo 'READ_ONLY / NO_DB_OR_N8N_MUTATION'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'clean_checkout=PASS'

python3 -m py_compile \
  "$ROOT/scripts/be-dom-001-transform-text-write.py" \
  "$ROOT/scripts/ux022r3-patch-quick-ingress-time.py" \
  "$ROOT/scripts/ux022r3-patch-receipt-operation-metadata.py" \
  "$ROOT/scripts/ux022r3-generate-category-settings-workflow.py"
echo 'backend_source_python_compile=PASS'

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-b68-$$-${id}.json"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  test -s "$target"
}

export_one "$QUICK_ID" "$WORK/quick.before.json"
export_one "$TEXT_ID" "$WORK/text.before.json"
export_one "$VOICE_ID" "$WORK/voice.before.json"
export_one "$PHOTO_ID" "$WORK/photo.before.json"
echo 'runtime_workflow_exports=PASS'

python3 "$ROOT/scripts/ux022r3-patch-quick-ingress-time.py" \
  "$WORK/quick.before.json" "$WORK/quick.candidate.json"
python3 "$ROOT/scripts/be-dom-001-transform-text-write.py" \
  "$WORK/text.before.json" "$WORK/text.candidate.json"
python3 "$ROOT/scripts/ux022r3-patch-receipt-operation-metadata.py" \
  "$WORK/photo.before.json" "$WORK/photo.candidate.json"
python3 "$ROOT/scripts/ux022r3-generate-category-settings-workflow.py" \
  --output "$WORK/category-settings.candidate.json"
echo 'backend_candidates_generated=PASS'

python3 - \
  "$WORK/quick.before.json" "$WORK/quick.candidate.json" \
  "$WORK/text.before.json" "$WORK/text.candidate.json" \
  "$WORK/photo.before.json" "$WORK/photo.candidate.json" \
  "$WORK/category-settings.candidate.json" <<'PY'
import copy
import hashlib
import json
import sys
from pathlib import Path


def one(path):
    raw = json.loads(Path(path).read_text(encoding='utf-8'))
    if isinstance(raw, list):
        assert len(raw) == 1, (path, len(raw))
        return raw[0]
    assert isinstance(raw, dict), path
    return raw


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def node(workflow, name):
    rows = [n for n in workflow.get('nodes', []) if n.get('name') == name]
    assert len(rows) == 1, (name, len(rows))
    return rows[0]


def normalize_metadata(workflow):
    result = copy.deepcopy(workflow)
    for key in ('updatedAt', 'createdAt', 'versionId', 'activeVersionId', 'versionCounter'):
        result.pop(key, None)
    return result

q0, q1, t0, t1, p0, p1, category = map(one, sys.argv[1:])

assert str(q0.get('id')) == 'UX022QuickInput202608'
assert str(q1.get('id')) == str(q0.get('id'))
assert digest(q0.get('connections') or {}) == digest(q1.get('connections') or {})
q0_nodes = {n.get('name'): n for n in q0.get('nodes', [])}
q1_nodes = {n.get('name'): n for n in q1.get('nodes', [])}
assert q0_nodes.keys() == q1_nodes.keys()
quick_changed = []
for name in q0_nodes:
    if digest(q0_nodes[name]) != digest(q1_nodes[name]):
        quick_changed.append(name)
assert quick_changed in ([], ['Voice To Text']), quick_changed
assert "$('Voice Prepare').first().json.message_date" in node(q1, 'Voice To Text')['parameters']['jsCode']
assert 'message_date:' in node(q1, 'Text Prepare')['parameters']['jsCode']
assert 'message_date:' in node(q1, 'Voice Prepare')['parameters']['jsCode']
print('quick_voice_ingress_propagation=PASS changed=' + ','.join(quick_changed or ['NONE']))

assert str(t0.get('id')) == 'f5ioJKyPTupUMV9h'
assert str(t1.get('id')) == str(t0.get('id'))
assert digest(t0.get('connections') or {}) == digest(t1.get('connections') or {})
t0_nodes = {n.get('name'): n for n in t0.get('nodes', [])}
t1_nodes = {n.get('name'): n for n in t1.get('nodes', [])}
assert t0_nodes.keys() == t1_nodes.keys()
text_changed = []
for name in t0_nodes:
    if digest(t0_nodes[name]) != digest(t1_nodes[name]):
        text_changed.append(name)
assert set(text_changed) <= {'Insert transaction text', 'Insert adjustment transaction', 'Insert opening balance'}
for name in ('Insert transaction text', 'Insert adjustment transaction'):
    query = str((node(t1, name).get('parameters') or {}).get('query', ''))
    assert "json.message_date" in query
    assert 'to_timestamp(' in query
    assert "'HH24:MI:SS'" in query
print('text_ingress_timestamp_candidate=PASS changed=' + ','.join(sorted(text_changed)))

assert str(p0.get('id')) == '5VC0EcFB21rwTfoI'
assert str(p1.get('id')) == str(p0.get('id'))
assert digest(p0.get('connections') or {}) == digest(p1.get('connections') or {})
p0_nodes = {n.get('name'): n for n in p0.get('nodes', [])}
p1_nodes = {n.get('name'): n for n in p1.get('nodes', [])}
assert p0_nodes.keys() == p1_nodes.keys()
photo_changed = []
for name in p0_nodes:
    if digest(p0_nodes[name]) != digest(p1_nodes[name]):
        photo_changed.append(name)
assert photo_changed in ([], ['Update product category']), photo_changed
photo_query = str((node(p1, 'Update product category').get('parameters') or {}).get('query', ''))
assert 'receipt_finalize_transaction_metadata_v1' in photo_query
assert 'receipt_assign_categories_v1' in photo_query
print('receipt_metadata_candidate_isolated=PASS changed=' + ','.join(photo_changed or ['NONE']))

assert str(category.get('id')) == 'UX022CategorySettings202608'
category_blob = json.dumps(category, ensure_ascii=False)
assert 'api/v1/categories' in category_blob
assert 'category_update_v1' in category_blob
assert 'insert into ' not in category_blob.lower()
assert 'update moneytrack.' not in category_blob.lower()
assert 'delete from ' not in category_blob.lower()
print('category_settings_thin_adapter_candidate=PASS')
PY

# Inspect the active Photo processor for a proven receipt-clock field. Do not
# infer success merely because receipt_date exists: the requirement is to take
# clock time from the receipt when the receipt contains it.
PHOTO_TIME_STATUS="$(python3 - "$WORK/photo.before.json" <<'PY'
import json
import re
import sys
from pathlib import Path

raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
wf=raw[0] if isinstance(raw,list) else raw
nodes=wf.get('nodes',[])
node_map={str(n.get('name')):n for n in nodes}
reverse={}
for source, outputs in (wf.get('connections') or {}).items():
    for channel in (outputs or {}).values():
        for branch in channel or []:
            for edge in branch or []:
                reverse.setdefault(str(edge.get('node') or ''),[]).append(str(source))
parse=[n for n in nodes if str(n.get('name') or '').lower() == 'parse receipt json']
if len(parse) != 1:
    print(f'BLOCKED|parse_receipt_json_count={len(parse)}')
    raise SystemExit(0)
parse_node=parse[0]
evidence=[json.dumps(parse_node.get('parameters') or {},ensure_ascii=False)]
for predecessor in reverse.get(str(parse_node.get('name')),[]):
    evidence.append(json.dumps((node_map.get(predecessor) or {}).get('parameters') or {},ensure_ascii=False))
blob='\n'.join(evidence)
explicit = bool(re.search(r'receipt_time|receipt_datetime', blob, re.I))
if not explicit:
    # A dedicated JSON field named exactly `time` is acceptable evidence; generic
    # prose mentioning time is not.
    explicit = bool(re.search(r'["\']time["\']\s*[:=]|\.time\b', blob, re.I))
print(('PASS' if explicit else 'BLOCKED') + '|explicit_receipt_clock_field=' + ('YES' if explicit else 'NO'))
PY
)"
printf 'photo_parser_time_contract=%s\n' "$PHOTO_TIME_STATUS"

# Report current category usage without changing schema/data. One-sided history
# is safe to infer; MIXED and UNUSED remain explicitly unresolved after 070.
cat > "$WORK/category-flow-forensic.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select 'category_flow_column=' || case when exists (
    select 1
      from information_schema.columns
     where table_schema='moneytrack'
       and table_name='category_catalog'
       and column_name='flow_type'
) then 'PRESENT' else 'ABSENT' end;

with usage as (
    select
        c.id,
        c.user_id,
        c.code,
        coalesce(nullif(to_jsonb(c)->>'flow_type',''),'') as current_flow,
        count(t.id) filter (where t.transaction_type='income')::bigint as income_count,
        count(t.id) filter (where t.transaction_type in ('expense','adjustment'))::bigint as expense_count
    from moneytrack.category_catalog c
    left join moneytrack.transactions t on t.category_id=c.id
    where coalesce(c.is_active,true)=true
    group by c.id,c.user_id,c.code
), classified as (
    select *, case
        when income_count>0 and expense_count=0 then 'INCOME'
        when expense_count>0 and income_count=0 then 'EXPENSE'
        when income_count>0 and expense_count>0 then 'MIXED'
        else 'UNUSED'
    end as observed_flow
    from usage
)
select format(
    'category_flow_row id=%s user_id=%s code=%s income=%s expense=%s observed=%s current=%s',
    id,user_id,code,income_count,expense_count,observed_flow,
    case when current_flow='' then 'NULL' else current_flow end
)
from classified
where user_id<>0
order by user_id,code;

with usage as (
    select
        c.id,
        c.user_id,
        count(t.id) filter (where t.transaction_type='income')::bigint as income_count,
        count(t.id) filter (where t.transaction_type in ('expense','adjustment'))::bigint as expense_count
    from moneytrack.category_catalog c
    left join moneytrack.transactions t on t.category_id=c.id
    where coalesce(c.is_active,true)=true and c.user_id<>0
    group by c.id,c.user_id
)
select 'category_flow_unresolved_after_safe_inference=' || count(*)
from usage
where (income_count=0 and expense_count=0) or (income_count>0 and expense_count>0);
SQL
CATEGORY_REPORT="$(ux022_db_psql_file "$WORK/category-flow-forensic.sql")"
printf '%s\n' "$CATEGORY_REPORT"

UNRESOLVED="$(sed -n 's/^category_flow_unresolved_after_safe_inference=//p' <<<"$CATEGORY_REPORT" | tail -n1)"
[[ "$UNRESOLVED" =~ ^[0-9]+$ ]] || UNRESOLVED='UNKNOWN'

if [[ "$PHOTO_TIME_STATUS" == PASS* ]]; then
  echo 'backend_7_receipt_clock_runtime_precondition=PASS'
else
  echo 'backend_7_receipt_clock_runtime_precondition=BLOCKED'
fi

if [[ "$UNRESOLVED" == '0' ]]; then
  echo 'backend_8_category_flow_manual_corrections=NONE_REQUIRED'
elif [[ "$UNRESOLVED" == 'UNKNOWN' ]]; then
  echo 'backend_8_category_flow_manual_corrections=UNKNOWN'
else
  echo "backend_8_category_flow_manual_corrections=REQUIRED count=$UNRESOLVED"
fi

echo 'backend_6_text_voice_top_level_classifier=NOT_PROVEN'
echo 'backend_6_receipt_projection=SOURCE_READY_SINGLE_CLASSIFIED_CATEGORY_ONLY'
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'BACKEND_6_8_FORENSIC=PASS'

if [[ "$PHOTO_TIME_STATUS" == PASS* ]]; then
  echo 'BACKEND_6_8_RUNTIME_APPLY_PRECONDITION=PASS_WITH_CATEGORY_CORRECTION_STAGE'
else
  echo 'BACKEND_6_8_RUNTIME_APPLY_PRECONDITION=BLOCKED_PHOTO_TIME_CONTRACT'
fi
