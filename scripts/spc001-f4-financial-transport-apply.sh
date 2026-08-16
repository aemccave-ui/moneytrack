#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
F4_PREVIEW_DIR=""
OUTPUT_DIR=""
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_DB_CONTAINER="${N8N_DB_CONTAINER:-postgres}"
FINANCIAL_ID="SPC001FinancialApi202608"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --f4-preview-dir) F4_PREVIEW_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_F4_FINANCIAL_TRANSPORT=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$F4_PREVIEW_DIR" && -n "$OUTPUT_DIR" ]] || {
  echo 'SPC001_F4_FINANCIAL_TRANSPORT=REFUSED expected_head_f4_preview_output_required' >&2
  exit 2
}
[[ "$F4_PREVIEW_DIR" = /* && "$OUTPUT_DIR" = /* ]] || { echo 'ERROR: absolute paths required' >&2; exit 2; }
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'SPC001_F4_FINANCIAL_TRANSPORT=REFUSED durable_output_required_not_tmp' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git python3 node docker sha256sum grep awk find sort cp sync curl tee sleep cmp; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing command $cmd" >&2; exit 1; }
done

[[ -z "$(git status --porcelain)" ]] || { echo 'SPC001_F4_FINANCIAL_TRANSPORT=FAIL dirty_checkout' >&2; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "SPC001_F4_FINANCIAL_TRANSPORT=FAIL head_mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}

for c in "$N8N_CONTAINER" "$N8N_DB_CONTAINER" moneytrack-db; do
  docker inspect "$c" >/dev/null 2>&1 || { echo "ERROR: container missing: $c" >&2; exit 1; }
  [[ "$(docker inspect "$c" --format '{{.State.Running}}')" == true ]] || { echo "ERROR: container not running: $c" >&2; exit 1; }
done

for f in "$F4_PREVIEW_DIR/preview-metadata.txt" "$F4_PREVIEW_DIR/source-head.txt" "$F4_PREVIEW_DIR/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "ERROR: F4 preview evidence missing: $f" >&2; exit 1; }
done
(
  cd "$F4_PREVIEW_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
grep -Fx 'SPC001_F4_PREVIEW=PASS' "$F4_PREVIEW_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'DB_MUTATION=NONE' "$F4_PREVIEW_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'N8N_MUTATION=NONE' "$F4_PREVIEW_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'PRODUCTION_FRONTEND_MUTATION=NONE' "$F4_PREVIEW_DIR/preview-metadata.txt" >/dev/null
F4_HEAD="$(cat "$F4_PREVIEW_DIR/source-head.txt")"
[[ "$F4_HEAD" =~ ^[0-9a-f]{40}$ ]]
git merge-base --is-ancestor "$F4_HEAD" "$HEAD_SHA"

mapfile -t CHANGED < <(git diff --name-only "$F4_HEAD..$HEAD_SHA")
for path in "${CHANGED[@]}"; do
  case "$path" in
    scripts/spc001-generate-financial-api.py|scripts/spc001-f4-financial-transport-source-gate.py|scripts/spc001-f4-financial-transport-verify.py|scripts/spc001-f4-financial-transport-apply.sh|.github/workflows/spc001-source-contract.yml) ;;
    *) echo "ERROR: non-transport source changed after accepted F4 preview: $path" >&2; exit 1 ;;
  esac
done
echo "F4_PREVIEW_TO_TRANSPORT_SAFE_DELTA=PASS files=${#CHANGED[@]}"
echo 'F4_PREVIEW_ACCEPTANCE_EVIDENCE=PASS'

python3 "$ROOT/scripts/spc001-f4-financial-transport-source-gate.py"
python3 "$ROOT/scripts/spc001-source-gate.py" --stage C

for cli in 'export:workflow --help' 'import:workflow --help' 'publish:workflow --help'; do
  docker exec "$N8N_CONTAINER" n8n $cli >/dev/null 2>&1 || { echo "ERROR: n8n CLI unavailable: $cli" >&2; exit 1; }
done
docker exec "$N8N_CONTAINER" n8n export:workflow --help 2>&1 | grep -Fq -- '--published'
echo 'N8N_CLI_GATE=PASS'

umask 077
mkdir -p "$OUTPUT_DIR/pre" "$OUTPUT_DIR/pre-after-backup" "$OUTPUT_DIR/post" "$OUTPUT_DIR/import" "$OUTPUT_DIR/rollback"
chmod 700 "$OUTPUT_DIR"
printf '%s\n' "$HEAD_SHA" > "$OUTPUT_DIR/source-head.txt"
printf '%s\n' "$F4_HEAD" > "$OUTPUT_DIR/f4-preview-head.txt"
sha256sum "$F4_PREVIEW_DIR/SHA256SUMS" > "$OUTPUT_DIR/f4-preview-manifest.sha256"

export_one() {
  local id="$1" out="$2" published="${3:-no}" remote
  remote="/tmp/spc001-f4-transport-export-${id}-$$.json"
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  if [[ "$published" == yes ]]; then
    docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --published --output="$remote" >/dev/null
  else
    docker exec "$N8N_CONTAINER" n8n export:workflow --id="$id" --output="$remote" >/dev/null
  fi
  docker cp "$N8N_CONTAINER:$remote" "$out" >/dev/null
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  [[ -s "$out" ]]
}

export_all_published() {
  local out="$1" remote="/tmp/spc001-f4-transport-all-published-$$.json"
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  docker exec "$N8N_CONTAINER" n8n export:workflow --all --published --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$out" >/dev/null
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  [[ -s "$out" ]]
}

wait_health() {
  local code="" i
  for i in $(seq 1 60); do
    code="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:5678/healthz || true)"
    [[ "$code" == 200 ]] && { echo 'N8N_HEALTH=PASS'; return 0; }
    sleep 1
  done
  echo "N8N_HEALTH=FAIL http=${code:-none}" >&2
  return 1
}

prepare_import() {
  local src="$1"
  local id="$2"
  local dst="$OUTPUT_DIR/import/$id.json"
  python3 - "$src" "$dst" "$id" <<'PY'
import json,sys
from pathlib import Path
src,dst,expected=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
raw=json.loads(src.read_text(encoding='utf-8'))
wf=raw[0] if isinstance(raw,list) and len(raw)==1 else raw
if not isinstance(wf,dict) or str(wf.get('id') or '')!=expected:
    raise SystemExit(f'candidate_identity expected={expected} actual={wf.get("id") if isinstance(wf,dict) else None}')
dst.write_text(json.dumps([wf],ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
  echo "$dst"
}

stage_import_payload() {
  local file="$1" remote="$2" log="$3"
  echo "+ stage import payload via stdin as n8n runtime user: $remote" >> "$log"
  docker exec -i "$N8N_CONTAINER" sh -ceu 'umask 077; cat > "$1"; test -s "$1"' sh "$remote" < "$file" >> "$log" 2>&1
}

import_workflow() {
  local file="$1"
  local id="$2"
  local remote="/tmp/spc001-f4-transport-import-${id}-$$.json"
  local log="$OUTPUT_DIR/import-$id.log"
  if ! stage_import_payload "$file" "$remote" "$log"; then
    echo "N8N_IMPORT_STAGE=FAIL id=$id log=$log" >&2
    cat "$log" >&2
    docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
    return 1
  fi
  echo "N8N_IMPORT_STAGE=PASS id=$id"
  if ! docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote" >> "$log" 2>&1; then
    echo "N8N_IMPORT=FAIL id=$id log=$log" >&2
    cat "$log" >&2
    docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
    return 1
  fi
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  echo "N8N_IMPORT=PASS id=$id"
}

publish_workflow() {
  local id="$1"
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id" >/dev/null
  echo "N8N_PUBLISH=PASS id=$id"
}

# Candidate is source-generated at the exact controlled HEAD.
python3 "$ROOT/scripts/spc001-generate-financial-api.py" --output "$OUTPUT_DIR/candidate-financial-api.json" \
  | tee "$OUTPUT_DIR/candidate-generate.txt"
CANDIDATE_IMPORT="$(prepare_import "$OUTPUT_DIR/candidate-financial-api.json" "$FINANCIAL_ID")"

# Freeze current published state and current Financial core before any mutation.
export_all_published "$OUTPUT_DIR/pre/all-published.json"
export_one "$FINANCIAL_ID" "$OUTPUT_DIR/pre/financial-current.json" no
python3 "$ROOT/scripts/spc001-f4-financial-transport-verify.py" pre \
  --candidate "$OUTPUT_DIR/candidate-financial-api.json" \
  --before-current "$OUTPUT_DIR/pre/financial-current.json" \
  --before-published "$OUTPUT_DIR/pre/all-published.json" \
  | tee "$OUTPUT_DIR/pre/runtime-verify.txt"

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init
ux022_db_psql_file "$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql" \
  2>&1 | tee "$OUTPUT_DIR/pre/live-315.txt"
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$OUTPUT_DIR/pre/live-315.txt" >/dev/null
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=END' "$OUTPUT_DIR/pre/live-315.txt" >/dev/null
echo 'LIVE_315_BEFORE_TRANSPORT=PASS'

# Fresh full PROD-H2 recovery point immediately before n8n metadata mutation.
BACKUP_ROOT="$OUTPUT_DIR/prod-h2" bash "$ROOT/scripts/prod-h2-backup-now.sh" \
  2>&1 | tee "$OUTPUT_DIR/prod-h2-backup.log"
mapfile -t BACKUP_DIRS < <(find "$OUTPUT_DIR/prod-h2" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#BACKUP_DIRS[@]}" -eq 1 ]] || { echo 'ERROR: fresh backup directory count' >&2; exit 1; }
BACKUP_DIR="${BACKUP_DIRS[0]}"
[[ -f "$BACKUP_DIR/COMPLETE" && -s "$BACKUP_DIR/n8n-metadata.dump" && -s "$BACKUP_DIR/SHA256SUMS" ]]
(
  cd "$BACKUP_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
N8N_BACKUP_SHA="$(sha256sum "$BACKUP_DIR/n8n-metadata.dump" | awk '{print $1}')"
echo "FRESH_PROD_H2_BACKUP=PASS path=$BACKUP_DIR n8n_metadata_sha256=$N8N_BACKUP_SHA"

# Guard against runtime edits during backup.
export_all_published "$OUTPUT_DIR/pre-after-backup/all-published.json"
export_one "$FINANCIAL_ID" "$OUTPUT_DIR/pre-after-backup/financial-current.json" no
cmp -s "$OUTPUT_DIR/pre/all-published.json" "$OUTPUT_DIR/pre-after-backup/all-published.json" || {
  python3 - "$OUTPUT_DIR/pre/all-published.json" "$OUTPUT_DIR/pre-after-backup/all-published.json" <<'PY'
import json,hashlib,sys

def many(p):
    x=json.load(open(p,encoding='utf-8')); return x if isinstance(x,list) else [x]
def core(w):
    v={k:w.get(k) for k in ('id','name','nodes','connections','settings')}
    return hashlib.sha256(json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
a={str(w.get('id')):core(w) for w in many(sys.argv[1])}
b={str(w.get('id')):core(w) for w in many(sys.argv[2])}
if a!=b: raise SystemExit('RUNTIME_DRIFT_DURING_BACKUP')
PY
}
python3 "$ROOT/scripts/spc001-f4-financial-transport-verify.py" pre \
  --candidate "$OUTPUT_DIR/candidate-financial-api.json" \
  --before-current "$OUTPUT_DIR/pre-after-backup/financial-current.json" \
  --before-published "$OUTPUT_DIR/pre-after-backup/all-published.json" >/dev/null
echo 'RUNTIME_STABLE_THROUGH_BACKUP=PASS'

MUTATED=0
PATCH_COMPLETE=0
ROLLBACK_RUNNING=0

rollback_metadata() {
  local rc="$1"
  [[ "$MUTATED" -eq 1 && "$PATCH_COMPLETE" -eq 0 ]] || return "$rc"
  [[ "$ROLLBACK_RUNNING" -eq 0 ]] || return "$rc"
  ROLLBACK_RUNNING=1
  trap - ERR HUP INT TERM
  set +e

  echo "ROLLBACK_TRIGGERED=YES rc=$rc" | tee "$OUTPUT_DIR/rollback/rollback.txt" >&2
  (cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS >/dev/null)
  HASH_RC=$?

  if [[ "$(docker inspect "$N8N_CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" == true ]]; then
    docker stop "$N8N_CONTAINER" >/dev/null 2>&1
    STOP_RC=$?
  else
    STOP_RC=0
  fi
  docker exec "$N8N_DB_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U n8n -d postgres -c \
    "select pg_terminate_backend(pid) from pg_stat_activity where datname='n8n' and pid<>pg_backend_pid();" >/dev/null 2>&1
  TERM_RC=$?
  docker exec "$N8N_DB_CONTAINER" dropdb -U n8n --if-exists n8n >/dev/null 2>&1
  DROP_RC=$?
  docker exec "$N8N_DB_CONTAINER" createdb -U n8n -O n8n n8n >/dev/null 2>&1
  CREATE_RC=$?
  docker exec -i "$N8N_DB_CONTAINER" pg_restore -U n8n -d n8n --exit-on-error \
    < "$BACKUP_DIR/n8n-metadata.dump" >/dev/null 2>&1
  RESTORE_RC=$?
  docker start "$N8N_CONTAINER" >/dev/null 2>&1
  START_RC=$?
  wait_health >> "$OUTPUT_DIR/rollback/rollback.txt" 2>&1
  HEALTH_RC=$?

  VERIFY_RC=1
  if [[ "$HASH_RC" -eq 0 && "$STOP_RC" -eq 0 && "$TERM_RC" -eq 0 && "$DROP_RC" -eq 0 && "$CREATE_RC" -eq 0 && "$RESTORE_RC" -eq 0 && "$START_RC" -eq 0 && "$HEALTH_RC" -eq 0 ]]; then
    export_all_published "$OUTPUT_DIR/rollback/all-published.json"
    python3 "$ROOT/scripts/spc001-f4-financial-transport-verify.py" rollback \
      --before-published "$OUTPUT_DIR/pre/all-published.json" \
      --rollback-published "$OUTPUT_DIR/rollback/all-published.json" \
      >> "$OUTPUT_DIR/rollback/rollback.txt" 2>&1
    VERIFY_RC=$?
  fi

  if [[ "$HASH_RC" -eq 0 && "$STOP_RC" -eq 0 && "$TERM_RC" -eq 0 && "$DROP_RC" -eq 0 && "$CREATE_RC" -eq 0 && "$RESTORE_RC" -eq 0 && "$START_RC" -eq 0 && "$HEALTH_RC" -eq 0 && "$VERIFY_RC" -eq 0 ]]; then
    echo 'ROLLBACK_N8N_METADATA=PASS' | tee -a "$OUTPUT_DIR/rollback/rollback.txt" >&2
  else
    echo "ROLLBACK_N8N_METADATA=FAIL backup=$BACKUP_DIR" | tee -a "$OUTPUT_DIR/rollback/rollback.txt" >&2
  fi
  echo 'ROLLBACK_MONEYTRACK_DB_MUTATION=NONE' >> "$OUTPUT_DIR/rollback/rollback.txt"
  set -e
  return "$rc"
}

on_error() {
  local rc=$?
  trap - ERR HUP INT TERM
  rollback_metadata "$rc" || true
  echo "SPC001_F4_FINANCIAL_TRANSPORT=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}

on_signal() {
  local sig="$1" rc=130
  [[ "$sig" == TERM ]] && rc=143
  [[ "$sig" == HUP ]] && rc=129
  trap - ERR HUP INT TERM
  rollback_metadata "$rc" || true
  echo "SPC001_F4_FINANCIAL_TRANSPORT=FAIL signal=$sig rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}

trap on_error ERR
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# First and only intended metadata mutation: replace/publish Financial API.
MUTATED=1
import_workflow "$CANDIDATE_IMPORT" "$FINANCIAL_ID"
publish_workflow "$FINANCIAL_ID"
echo 'N8N_WORKFLOW_MUTATION=FINANCIAL_TRANSPORT_ONLY'
echo 'CONTROL_WORKFLOW_MUTATION=NONE'
echo 'CAPTURE_WORKFLOW_MUTATION=NONE'

docker restart "$N8N_CONTAINER" >/dev/null
wait_health

export_all_published "$OUTPUT_DIR/post/all-published.json"
export_one "$FINANCIAL_ID" "$OUTPUT_DIR/post/financial-current.json" no
python3 "$ROOT/scripts/spc001-f4-financial-transport-verify.py" post \
  --candidate "$OUTPUT_DIR/candidate-financial-api.json" \
  --before-published "$OUTPUT_DIR/pre/all-published.json" \
  --after-current "$OUTPUT_DIR/post/financial-current.json" \
  --after-published "$OUTPUT_DIR/post/all-published.json" \
  | tee "$OUTPUT_DIR/post/runtime-verify.txt"

python3 "$ROOT/scripts/spc001-audit-workflow-tenancy.py" --reachable-only \
  "$OUTPUT_DIR/post/financial-current.json" \
  | tee "$OUTPUT_DIR/post/tenancy-audit.txt"
grep -Fx 'SPC001_TENANCY_AUDIT=PASS' "$OUTPUT_DIR/post/tenancy-audit.txt" >/dev/null
echo 'FINANCIAL_TENANCY_AUDIT=PASS'

ux022_db_psql_file "$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql" \
  2>&1 | tee "$OUTPUT_DIR/post/live-315.txt"
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$OUTPUT_DIR/post/live-315.txt" >/dev/null
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=END' "$OUTPUT_DIR/post/live-315.txt" >/dev/null
echo 'LIVE_315_AFTER_TRANSPORT=PASS'
cmp -s "$OUTPUT_DIR/pre/live-315.txt" "$OUTPUT_DIR/post/live-315.txt"
echo 'LIVE_315_UNCHANGED=PASS'

PATCH_COMPLETE=1
trap - ERR HUP INT TERM

{
  echo "HEAD=$HEAD_SHA"
  echo "F4_PREVIEW_HEAD=$F4_HEAD"
  echo "F4_PREVIEW_EVIDENCE_DIR=$F4_PREVIEW_DIR"
  echo "FRESH_BACKUP_DIR=$BACKUP_DIR"
  echo "N8N_METADATA_BACKUP_SHA256=$N8N_BACKUP_SHA"
  echo "FINANCIAL_WORKFLOW_ID=$FINANCIAL_ID"
  echo 'FINANCIAL_ERROR_TRANSPORT=NESTED_DOMAIN_CODE_PRESERVED'
  echo 'LIVE_315_BEFORE_TRANSPORT=PASS'
  echo 'LIVE_315_AFTER_TRANSPORT=PASS'
  echo 'LIVE_315_UNCHANGED=PASS'
  echo 'DB_MUTATION=NONE'
  echo 'N8N_MUTATION=FINANCIAL_TRANSPORT_PATCH_APPLIED'
  echo 'N8N_WORKFLOW_MUTATION=FINANCIAL_TRANSPORT_ONLY'
  echo 'CONTROL_WORKFLOW_MUTATION=NONE'
  echo 'CAPTURE_WORKFLOW_MUTATION=NONE'
  echo 'PREVIEW_MUTATION=NONE'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'N8N_ROLLBACK=NOT_REQUIRED'
  echo 'SPC001_F4_FINANCIAL_TRANSPORT=PASS'
} > "$OUTPUT_DIR/metadata.txt"

python3 - "$OUTPUT_DIR" "$BACKUP_DIR" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]).resolve(); backup=Path(sys.argv[2]).resolve(); out=root/'SHA256SUMS'; rows=[]
for p in sorted(root.rglob('*')):
    if not p.is_file() or p==out or backup in p.parents: continue
    h=hashlib.sha256(p.read_bytes()).hexdigest(); rows.append(f"{h}  {p.relative_to(root)}\n")
manifest=backup/'SHA256SUMS'
rows.append(f"{hashlib.sha256(manifest.read_bytes()).hexdigest()}  {manifest.relative_to(root)}\n")
out.write_text(''.join(rows),encoding='utf-8')
PY
sync

echo "SPC001_F4_FINANCIAL_TRANSPORT_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=FINANCIAL_TRANSPORT_PATCH_APPLIED'
echo 'N8N_WORKFLOW_MUTATION=FINANCIAL_TRANSPORT_ONLY'
echo 'CONTROL_WORKFLOW_MUTATION=NONE'
echo 'CAPTURE_WORKFLOW_MUTATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'ROLLBACK_TRIGGERED=NO'
echo 'SPC001_F4_FINANCIAL_TRANSPORT=PASS'
