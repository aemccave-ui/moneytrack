#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
QUICK_ID="UX022QuickInput202608"
PHOTO_ID="5VC0EcFB21rwTfoI"
DASHBOARD_ID="7TJ2xQTxLsTydXZc"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_RUNTIME_REPAIR_BACKUP_DIR:-/var/backups/moneytrack/ux022r3-runtime-repair/$STAMP}"
WORK="$(mktemp -d /tmp/ux022r3-runtime-repair-apply.XXXXXX)"
DB_MUTATED=0
N8N_MUTATED=0
SUCCESS=0

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

cleanup() { rm -rf "$WORK"; }
container_tmp_rm() { docker exec -u 0 "$N8N_CONTAINER" rm -f "$1" >/dev/null 2>&1 || true; }

export_one() {
  local id="$1"
  local target="$2"
  local remote="/tmp/ux022r3-runtime-repair-export-$$-${id}.json"
  container_tmp_rm "$remote"
  docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  container_tmp_rm "$remote"
}

import_publish() {
  local file="$1"
  local id="$2"
  local remote="/tmp/ux022r3-runtime-repair-import-$$-${id}.json"
  container_tmp_rm "$remote"
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote"
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id"
  container_tmp_rm "$remote"
}

restore_dashboard_db() {
  local restore="$WORK/restore-dashboard-db.sql"
  {
    echo 'begin;'
    cat "$BACKUP_DIR/dashboard-v1.before.sql"
    echo 'drop function if exists moneytrack.finance_dashboard_read_model_v2(bigint, date);'
    echo 'commit;'
  } > "$restore"
  ux022_db_psql_file "$restore" >/dev/null
}

rollback() {
  local status="${1:-1}"
  trap - ERR EXIT
  echo "UX022R3_RUNTIME_REGRESSION_REPAIR_APPLY=FAIL status=$status" >&2
  if (( N8N_MUTATED )); then
    import_publish "$BACKUP_DIR/quick.before.json" "$QUICK_ID" && echo 'rollback_quick=PASS' >&2 || echo 'rollback_quick=FAIL' >&2
    import_publish "$BACKUP_DIR/photo.before.json" "$PHOTO_ID" && echo 'rollback_photo=PASS' >&2 || echo 'rollback_photo=FAIL' >&2
    docker restart "$N8N_CONTAINER" >/dev/null && echo 'rollback_n8n_restart=PASS' >&2 || echo 'rollback_n8n_restart=FAIL' >&2
  fi
  if (( DB_MUTATED )); then
    restore_dashboard_db && echo 'rollback_dashboard_db=PASS' >&2 || echo 'rollback_dashboard_db=FAIL' >&2
  fi
  echo 'rollback_dashboard_workflow=NOT_TOUCHED' >&2
  echo "rollback_point=$BACKUP_DIR" >&2
  cleanup
  exit "$status"
}

on_exit() {
  local status=$?
  if (( status != 0 && SUCCESS == 0 && (DB_MUTATED || N8N_MUTATED) )); then
    rollback "$status"
  fi
  cleanup
}
trap 'rollback $?' ERR
trap on_exit EXIT

for cmd in docker curl python3; do command -v "$cmd" >/dev/null; done
docker inspect "$N8N_CONTAINER" >/dev/null
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

echo '# Phase'
echo 'UX-022R3 runtime regression controlled repair'
echo '# Gate'
echo 'CONTROLLED_DB_AND_N8N_MUTATION_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'DASHBOARD_WORKFLOW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'PREVIEW_FRONTEND_MUTATION=NONE'

bash "$ROOT/scripts/ux022r3-runtime-regression-repair-gate.sh"
echo 'repair_preflight=PASS'

mkdir -p "$BACKUP_DIR"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
ux022_db_pg_dump_schema moneytrack "$BACKUP_DIR/moneytrack-schema-before.dump"
export_one "$QUICK_ID" "$BACKUP_DIR/quick.before.json"
export_one "$PHOTO_ID" "$BACKUP_DIR/photo.before.json"
export_one "$DASHBOARD_ID" "$BACKUP_DIR/dashboard.before.json"

cat > "$WORK/capture-dashboard-v1.sql" <<'SQL'
\set QUIET 1
\pset tuples_only on
\pset format unaligned
select pg_get_functiondef('moneytrack.finance_dashboard_read_model_v1(bigint,date)'::regprocedure) || E';';
SQL
ux022_db_psql_file "$WORK/capture-dashboard-v1.sql" > "$BACKUP_DIR/dashboard-v1.before.sql"
grep -qi 'create or replace function moneytrack.finance_dashboard_read_model_v1' "$BACKUP_DIR/dashboard-v1.before.sql"

echo "runtime_backup=PASS path=$BACKUP_DIR"
echo 'dashboard_v1_definition_backup=PASS'
echo 'dashboard_workflow_draft_backup=PASS'

python3 "$ROOT/scripts/ux022r3-patch-runtime-regressions.py" \
  --quick-before "$BACKUP_DIR/quick.before.json" \
  --photo-before "$BACKUP_DIR/photo.before.json" \
  --quick-after "$WORK/quick.after.json" \
  --photo-after "$WORK/photo.after.json"

ux022_db_psql_file "$ROOT/db/domain/UX-022/060_runtime_regression_repair.sql" >/dev/null
DB_MUTATED=1
echo 'dashboard_db_switch_apply=PASS'

cat > "$WORK/dashboard-db-verify.sql" <<'SQL'
\set QUIET 1
\pset tuples_only on
\pset format unaligned
select 'dashboard_v2_function=' || case when to_regprocedure('moneytrack.finance_dashboard_read_model_v2(bigint,date)') is null then 'ABSENT' else 'PRESENT' end;
select 'dashboard_v1_wrapper=' || case when position('finance_dashboard_read_model_v2' in pg_get_functiondef('moneytrack.finance_dashboard_read_model_v1(bigint,date)'::regprocedure)) > 0 then 'PASS' else 'FAIL' end;
select 'dashboard_v1_user1_net_worth=' || coalesce(net_worth::text,'NULL') from moneytrack.finance_dashboard_read_model_v1(1,current_date);
select 'dashboard_v2_user1_net_worth=' || coalesce(net_worth::text,'NULL') from moneytrack.finance_dashboard_read_model_v2(1,current_date);
SQL
DB_VERIFY="$(ux022_db_psql_file "$WORK/dashboard-db-verify.sql")"
printf '%s\n' "$DB_VERIFY"
grep -q '^dashboard_v2_function=PRESENT$' <<<"$DB_VERIFY"
grep -q '^dashboard_v1_wrapper=PASS$' <<<"$DB_VERIFY"
V1_NET="$(sed -n 's/^dashboard_v1_user1_net_worth=//p' <<<"$DB_VERIFY")"
V2_NET="$(sed -n 's/^dashboard_v2_user1_net_worth=//p' <<<"$DB_VERIFY")"
[[ -n "$V1_NET" && "$V1_NET" == "$V2_NET" ]] || { echo 'dashboard_v1_v2_net_worth_match=FAIL' >&2; false; }
echo 'dashboard_v1_v2_net_worth_match=PASS'

N8N_MUTATED=1
import_publish "$WORK/quick.after.json" "$QUICK_ID"
import_publish "$WORK/photo.after.json" "$PHOTO_ID"
docker restart "$N8N_CONTAINER" >/dev/null
echo 'n8n_quick_photo_publish_restart=PASS'

ready_photo=0
ready_dashboard=0
photo_code=''
dash_code=''
for _ in $(seq 1 30); do
  photo_code="$(curl -sS -X POST -o "$WORK/photo-ready.json" -w '%{http_code}' "$API_BASE/api/v1/transaction/photo" || true)"
  dash_code="$(curl -sS -o "$WORK/dashboard-ready.json" -w '%{http_code}' "$API_BASE/api/v1/dashboard" || true)"
  [[ "$photo_code" == '401' ]] && ready_photo=1
  [[ "$dash_code" == '401' ]] && ready_dashboard=1
  (( ready_photo && ready_dashboard )) && break
  sleep 1
done
(( ready_photo )) || { echo "photo_readiness=FAIL http=${photo_code:-}" >&2; false; }
(( ready_dashboard )) || { echo "dashboard_readiness=FAIL http=${dash_code:-}" >&2; false; }
echo 'photo_readiness=PASS http=401'
echo 'dashboard_readiness=PASS http=401'

export_one "$QUICK_ID" "$WORK/quick.runtime.json"
export_one "$PHOTO_ID" "$WORK/photo.runtime.json"
export_one "$DASHBOARD_ID" "$WORK/dashboard.runtime.json"
python3 - "$WORK/quick.runtime.json" "$WORK/photo.runtime.json" "$BACKUP_DIR/dashboard.before.json" "$WORK/dashboard.runtime.json" <<'PY'
import hashlib,json,sys
from pathlib import Path

def one(p):
    x=json.loads(Path(p).read_text(encoding='utf-8'))
    return x[0] if isinstance(x,list) else x

def node(wf,name):
    rows=[n for n in wf.get('nodes',[]) if n.get('name')==name]
    assert len(rows)==1,(name,len(rows))
    return rows[0]

def digest(v):
    return hashlib.sha256(json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()

q,p,d_before,d_after=map(one,sys.argv[1:])
for wf in (q,p):
    assert wf.get('active') is True
    assert wf.get('versionId')==wf.get('activeVersionId')
prep=node(q,'Photo Prepare')['parameters']['jsCode']
assert 'receipt_source_identity:' in prep
assert "telegram_file_id: $('Photo Hash').first().json.photo_identity" not in prep
fmt=node(q,'Photo Format')['parameters']['jsCode']
assert 'PHOTO_PROCESSOR_ERROR' in fmt
exact=node(p,'Check duplicate receipt')['parameters']['query']
assert 'receipt_source_identity || $json.telegram_file_id' in exact
ingest=[n for n in p.get('nodes',[]) if 'receipt_ingest_v1' in str((n.get('parameters') or {}).get('query',''))]
assert ingest and all('receipt_source_identity' in n['parameters']['query'] for n in ingest)
assert d_before.get('versionId')==d_after.get('versionId')
assert d_before.get('activeVersionId')==d_after.get('activeVersionId')
assert digest(d_before.get('nodes') or [])==digest(d_after.get('nodes') or [])
assert digest(d_before.get('connections') or {})==digest(d_after.get('connections') or {})
blob=json.dumps(d_after.get('nodes',[]),ensure_ascii=False)
assert blob.count('finance_dashboard_read_model_v1')==1
assert 'finance_dashboard_read_model_v2' not in blob
print('published_quick_photo_contract=PASS')
print('dashboard_workflow_unchanged=PASS')
print(f'dashboard_versionId_preserved={d_after.get("versionId","")}')
print(f'dashboard_activeVersionId_preserved={d_after.get("activeVersionId","")}')
PY

SUCCESS=1
DB_MUTATED=0
N8N_MUTATED=0
trap - ERR

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=finance_dashboard_read_model_v2_PLUS_v1_WRAPPER_APPLIED'
echo 'N8N_MUTATION=QUICK_PHOTO_PUBLISHED'
echo 'DASHBOARD_WORKFLOW_MUTATION=NONE'
echo 'PREVIEW_FRONTEND_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'TELEGRAM_RUNTIME_ACCEPTANCE=PENDING'
echo 'UX022R3_RUNTIME_REGRESSION_REPAIR_APPLY=PASS'
