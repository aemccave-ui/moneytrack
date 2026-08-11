#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
QUICK_ID="UX022QuickInput202608"
PHOTO_ID="5VC0EcFB21rwTfoI"
DASHBOARD_ID="7TJ2xQTxLsTydXZc"
WORK="$(mktemp -d /tmp/ux022r3-runtime-repair-gate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

echo '# Phase'
echo 'UX-022R3 runtime regression repair preflight'
echo '# Gate'
echo 'READ_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"

bash -n "$ROOT/scripts/ux022r3-runtime-regression-repair-gate.sh"
python3 -m py_compile "$ROOT/scripts/ux022r3-patch-runtime-regressions.py"
echo 'source_syntax=PASS'

# Validate the additive dashboard v2 function in a transaction that is always rolled back.
python3 - "$ROOT/db/domain/UX-022/060_runtime_regression_repair.sql" "$WORK/060.rollback.sql" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
lines=src.splitlines()
for i,line in enumerate(lines):
    if line.strip().lower()=='begin;':
        lines[i]='begin;'
        break
for i in range(len(lines)-1,-1,-1):
    if lines[i].strip().lower()=='commit;':
        lines[i]='rollback;'
        break
else:
    raise SystemExit('migration_commit_missing')
Path(sys.argv[2]).write_text('\n'.join(lines)+'\n',encoding='utf-8')
PY
ux022_db_psql_file "$WORK/060.rollback.sql" >/dev/null
echo 'dashboard_v2_db_rollback_validation=PASS'

container_tmp_rm() {
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$1" >/dev/null 2>&1 || true
}

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-runtime-repair-gate-$$-${id}.json"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  container_tmp_rm "$remote"
}

docker inspect "$N8N_CONTAINER" >/dev/null
export_one "$QUICK_ID" "$WORK/quick.before.json"
export_one "$PHOTO_ID" "$WORK/photo.before.json"
export_one "$DASHBOARD_ID" "$WORK/dashboard.before.json"
echo 'workflow_export_runtime_smoke=PASS'

python3 - "$WORK/quick.before.json" "$WORK/photo.before.json" "$WORK/dashboard.before.json" <<'PY'
import json,sys
from pathlib import Path

def one(p):
    x=json.loads(Path(p).read_text(encoding='utf-8'))
    return x[0] if isinstance(x,list) else x

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    assert len(rows)==1,(name,len(rows))
    return rows[0]

q,p,d=map(one,sys.argv[1:])
for wf,wid in ((q,'UX022QuickInput202608'),(p,'5VC0EcFB21rwTfoI'),(d,'7TJ2xQTxLsTydXZc')):
    assert str(wf.get('id'))==wid,(wf.get('id'),wid)
    assert wf.get('active') is True,wid
    assert wf.get('versionId')==wf.get('activeVersionId'),f'{wid}_unpublished_drift'
prep=node(q,'Photo Prepare').get('parameters',{}).get('jsCode','')
assert "telegram_file_id: $('Photo Hash').first().json.photo_identity" in prep
assert 'receipt_source_identity:' not in prep
exact=node(p,'Check duplicate receipt').get('parameters',{}).get('query','')
assert 'String($json.telegram_file_id || "")' in exact
assert 'receipt_source_identity' not in exact
assert any('receipt_ingest_v1' in str((n.get('parameters') or {}).get('query','')) for n in p.get('nodes',[]))
blob=json.dumps(d.get('nodes',[]),ensure_ascii=False)
assert blob.count('finance_dashboard_read_model_v1')==1,blob.count('finance_dashboard_read_model_v1')
assert 'finance_dashboard_read_model_v2' not in blob
print('runtime_before_contract=EXPECTED_REGRESSED_STATE')
PY

python3 "$ROOT/scripts/ux022r3-patch-runtime-regressions.py" \
  --quick-before "$WORK/quick.before.json" \
  --photo-before "$WORK/photo.before.json" \
  --dashboard-before "$WORK/dashboard.before.json" \
  --quick-after "$WORK/quick.after.json" \
  --photo-after "$WORK/photo.after.json" \
  --dashboard-after "$WORK/dashboard.after.json"

python3 - "$WORK/quick.after.json" "$WORK/photo.after.json" "$WORK/dashboard.after.json" <<'PY'
import json,sys
from pathlib import Path

def one(p):
    x=json.loads(Path(p).read_text(encoding='utf-8'))
    return x[0] if isinstance(x,list) else x

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    assert len(rows)==1,(name,len(rows))
    return rows[0]
q,p,d=map(one,sys.argv[1:])
prep=node(q,'Photo Prepare')['parameters']['jsCode']
assert 'receipt_source_identity:' in prep
assert "telegram_file_id: $('Photo Hash').first().json.photo_identity" not in prep
fmt=node(q,'Photo Format')['parameters']['jsCode']
assert 'PHOTO_PROCESSOR_ERROR' in fmt and 'RECEIPT_DUPLICATE_EXACT' in fmt and 'RECEIPT_DUPLICATE_SEMANTIC' in fmt
exact=node(p,'Check duplicate receipt')['parameters']['query']
assert 'receipt_source_identity || $json.telegram_file_id' in exact
ingest=[n for n in p.get('nodes',[]) if 'receipt_ingest_v1' in str((n.get('parameters') or {}).get('query',''))]
assert ingest
assert all('receipt_source_identity' in n['parameters']['query'] for n in ingest)
blob=json.dumps(d.get('nodes',[]),ensure_ascii=False)
assert 'finance_dashboard_read_model_v1' not in blob
assert blob.count('finance_dashboard_read_model_v2')==1
print('candidate_contract=PASS')
PY

echo 'N8N_MUTATION=NONE'
echo 'DB_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
echo 'UX022R3_RUNTIME_REGRESSION_REPAIR_PREFLIGHT=PASS'
