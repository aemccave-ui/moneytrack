#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR=""
E1_DIR=""
EXPECTED_HEAD=""
APPLY=0
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_DB_CONTAINER="${N8N_DB_CONTAINER:-postgres}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ -n "${2:-}" ]] || { echo 'ERROR: --output-dir requires a value' >&2; exit 2; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --e1-dir)
      [[ -n "${2:-}" ]] || { echo 'ERROR: --e1-dir requires a value' >&2; exit 2; }
      E1_DIR="$2"; shift 2 ;;
    --expected-head)
      [[ -n "${2:-}" ]] || { echo 'ERROR: --expected-head requires a value' >&2; exit 2; }
      EXPECTED_HEAD="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_N8N_CUTOVER=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$OUTPUT_DIR" && -n "$E1_DIR" && -n "$EXPECTED_HEAD" ]] || {
  echo 'SPC001_N8N_CUTOVER=REFUSED output_e1_expected_head_required' >&2
  exit 2
}
[[ "$OUTPUT_DIR" = /* && "$E1_DIR" = /* ]] || { echo 'ERROR: absolute paths required' >&2; exit 2; }
case "$OUTPUT_DIR" in
  /tmp|/tmp/*) echo 'SPC001_N8N_CUTOVER=REFUSED durable_output_required_not_tmp' >&2; exit 2 ;;
esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output path already exists: $OUTPUT_DIR" >&2; exit 2; }
[[ -d "$E1_DIR" ]] || { echo "ERROR: E1 directory missing: $E1_DIR" >&2; exit 2; }

for command_name in python3 sha256sum git docker grep awk find sort cp sync curl tee sleep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "SPC001_N8N_CUTOVER=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

[[ -z "$(git status --porcelain)" ]] || { echo 'SPC001_N8N_CUTOVER=FAIL dirty_checkout' >&2; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "SPC001_N8N_CUTOVER=FAIL head_mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}

for c in "$N8N_CONTAINER" "$N8N_DB_CONTAINER" moneytrack-db; do
  docker inspect "$c" >/dev/null 2>&1 || { echo "SPC001_N8N_CUTOVER=FAIL container_missing=$c" >&2; exit 1; }
  [[ "$(docker inspect "$c" --format '{{.State.Running}}')" == true ]] || {
    echo "SPC001_N8N_CUTOVER=FAIL container_not_running=$c" >&2
    exit 1
  }
done

E1_METADATA="$E1_DIR/preflight-metadata.txt"
E1_PLAN="$E1_DIR/cutover-plan.json"
E1_MANIFEST="$E1_DIR/SHA256SUMS"
for f in "$E1_METADATA" "$E1_PLAN" "$E1_MANIFEST"; do
  [[ -s "$f" ]] || { echo "SPC001_N8N_CUTOVER=FAIL e1_file_missing=$f" >&2; exit 1; }
done
(
  cd "$E1_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
for marker in \
  'SPC001_N8N_CUTOVER_PREFLIGHT=PASS' \
  'DB_MUTATION=NONE' \
  'N8N_IMPORT=NONE' \
  'N8N_PUBLISH=NONE' \
  'N8N_UNPUBLISH=NONE'; do
  grep -Fx "$marker" "$E1_METADATA" >/dev/null
done
E1_MANIFEST_SHA="$(sha256sum "$E1_MANIFEST" | awk '{print $1}')"
echo "E1_EVIDENCE_INTEGRITY=PASS manifest_sha256=$E1_MANIFEST_SHA"

python3 - "$E1_PLAN" <<'PY'
import json, sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
assert p['contract']=='SPC001-E1-cutover-plan-v1'
assert p['global_survivor']['workflow_id']=='7TJ2xQTxLsTydXZc'
assert len(p['global_survivor']['routes'])==2
assert p['financial_candidate']['workflow_id']=='SPC001FinancialApi202608'
assert len(p['financial_candidate']['routes'])==30
assert p['control_candidate']['workflow_id']=='SPC001ControlApi202608'
assert len(p['control_candidate']['routes'])==13
assert len(p['legacy_financial_retire_workflow_ids'])==9
assert set(p['capture_candidates'])=={'quick_input','text_processor','voice_processor','photo_processor','bot'}
print('E1_CUTOVER_PLAN_CONTRACT=PASS')
PY

mapfile -t RETIRE_IDS < <(python3 - "$E1_PLAN" <<'PY'
import json, sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
for x in p['legacy_financial_retire_workflow_ids']:
    print(x)
PY
)

SURVIVOR_ID="7TJ2xQTxLsTydXZc"
FINANCIAL_ID="SPC001FinancialApi202608"
CONTROL_ID="SPC001ControlApi202608"
BOT_ID="DER2Lc3dT2afyQhy"
QUICK_ID="UX022QuickInput202608"
TEXT_ID="f5ioJKyPTupUMV9h"
VOICE_ID="Td7kvvrtqQK0FTJg"
PHOTO_ID="5VC0EcFB21rwTfoI"
CAPTURE_IDS=("$BOT_ID" "$QUICK_ID" "$TEXT_ID" "$VOICE_ID" "$PHOTO_ID")

for cli in 'export:workflow --help' 'import:workflow --help' 'publish:workflow --help' 'unpublish:workflow --help'; do
  docker exec "$N8N_CONTAINER" n8n $cli >/dev/null 2>&1 || {
    echo "SPC001_N8N_CUTOVER=FAIL n8n_cli_missing=$cli" >&2
    exit 1
  }
done
docker exec "$N8N_CONTAINER" n8n export:workflow --help 2>&1 | grep -Fq -- '--published'
echo 'N8N_CLI_GATE=PASS'

umask 077
mkdir -p \
  "$OUTPUT_DIR/pre/current" \
  "$OUTPUT_DIR/pre/published" \
  "$OUTPUT_DIR/pre-after-backup/current" \
  "$OUTPUT_DIR/pre-after-backup/published" \
  "$OUTPUT_DIR/post/current" \
  "$OUTPUT_DIR/rollback" \
  "$OUTPUT_DIR/import"
chmod 700 "$OUTPUT_DIR"

export_one() {
  local id="$1" out="$2" published="${3:-no}" remote
  remote="/tmp/spc001-e2-export-${id}-$$.json"
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
  local out="$1" remote="/tmp/spc001-e2-all-published-$$.json"
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  docker exec "$N8N_CONTAINER" n8n export:workflow --all --published --output="$remote" >/dev/null
  docker cp "$N8N_CONTAINER:$remote" "$out" >/dev/null
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  [[ -s "$out" ]]
}

wait_health() {
  local code=""
  local i
  for i in $(seq 1 45); do
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
import json, sys
from pathlib import Path
src,dst,expected=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
raw=json.loads(src.read_text(encoding='utf-8'))
if isinstance(raw,list):
    if len(raw)!=1: raise SystemExit('candidate_workflow_count')
    wf=raw[0]
else:
    wf=raw
if not isinstance(wf,dict) or str(wf.get('id') or '')!=expected:
    actual=wf.get('id') if isinstance(wf,dict) else None
    raise SystemExit(f'candidate_identity expected={expected} actual={actual}')
dst.write_text(json.dumps([wf],ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
  echo "$dst"
}

stage_import_payload() {
  local file="$1"
  local remote="$2"
  local log="$3"
  echo "+ stage import payload via stdin as n8n runtime user: $remote" >> "$log"
  docker exec -i "$N8N_CONTAINER" sh -ceu \
    'umask 077; cat > "$1"; test -s "$1"' sh "$remote" \
    < "$file" >> "$log" 2>&1
}

import_workflow() {
  local file="$1"
  local id="$2"
  local remote="/tmp/spc001-e2-import-${id}-$$.json"
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

unpublish_workflow() {
  local id="$1"
  docker exec "$N8N_CONTAINER" n8n unpublish:workflow --id="$id" >/dev/null
  echo "N8N_UNPUBLISH=PASS id=$id"
}

was_published_e1() {
  local id="$1"
  python3 - "$E1_DIR/all-published.json" "$id" <<'PY'
import json,sys
raw=json.load(open(sys.argv[1],encoding='utf-8'))
if isinstance(raw,dict): raw=[raw]
raise SystemExit(0 if any(str(x.get('id') or '')==sys.argv[2] for x in raw) else 1)
PY
}

# E1 freeze is the accepted pre-cutover runtime snapshot. Export fresh current
# state and require exact core/published parity before any mutation.
export_all_published "$OUTPUT_DIR/pre/all-published.json"
cp "$OUTPUT_DIR/pre/all-published.json" "$OUTPUT_DIR/rollback/before-all-published.json"
for id in "$SURVIVOR_ID" "${RETIRE_IDS[@]}"; do
  export_one "$id" "$OUTPUT_DIR/pre/published/$id.json" yes
done
for id in "${CAPTURE_IDS[@]}"; do
  export_one "$id" "$OUTPUT_DIR/pre/current/$id.json" no
done
python3 "$ROOT/scripts/spc001-n8n-cutover-verify.py" pre \
  --e1-dir "$E1_DIR" --runtime-dir "$OUTPUT_DIR/pre"

NEW_ID_COUNT="$(docker exec "$N8N_DB_CONTAINER" psql -X -q -At -U n8n -d n8n -c \
  "select count(*) from workflow_entity where id in ('$FINANCIAL_ID','$CONTROL_ID');")"
[[ "$NEW_ID_COUNT" == 0 ]] || {
  echo "SPC001_N8N_CUTOVER=FAIL new_workflow_id_already_exists count=$NEW_ID_COUNT" >&2
  exit 1
}
echo 'NEW_WORKFLOW_IDS_ABSENT=PASS'

for id in "$BOT_ID" "$QUICK_ID"; do
  was_published_e1 "$id" || {
    echo "SPC001_N8N_CUTOVER=FAIL required_ingress_not_published_e1 id=$id" >&2
    exit 1
  }
done

# Fail closed if any active published workflow outside the frozen capture set
# references the processor IDs that will be replaced while Bot/Quick are down.
python3 - "$OUTPUT_DIR/pre/all-published.json" "$BOT_ID" "$QUICK_ID" "$TEXT_ID" "$VOICE_ID" "$PHOTO_ID" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
if isinstance(raw,dict): raw=[raw]
capture=set(sys.argv[2:])
callees=set(sys.argv[4:])
bad=[]
for wf in raw:
    wid=str(wf.get('id') or '')
    if wid in capture:
        continue
    blob=json.dumps(wf.get('nodes') or [],ensure_ascii=False)
    hit=sorted(x for x in callees if x in blob)
    if hit:
        bad.append((wid,hit))
if bad:
    raise SystemExit('CAPTURE_EXTERNAL_CALLER_GATE=FAIL '+json.dumps(bad))
print('CAPTURE_EXTERNAL_CALLER_GATE=PASS')
PY

# Fresh PROD-H2 recovery point immediately before first persistent n8n change.
BACKUP_ROOT="$OUTPUT_DIR/prod-h2" bash "$ROOT/scripts/prod-h2-backup-now.sh" \
  2>&1 | tee "$OUTPUT_DIR/prod-h2-backup.log"
mapfile -t BACKUP_DIRS < <(find "$OUTPUT_DIR/prod-h2" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#BACKUP_DIRS[@]}" -eq 1 ]] || {
  echo 'SPC001_N8N_CUTOVER=FAIL fresh_backup_directory_count' >&2
  exit 1
}
BACKUP_DIR="${BACKUP_DIRS[0]}"
[[ -f "$BACKUP_DIR/COMPLETE" && -s "$BACKUP_DIR/n8n-metadata.dump" && -s "$BACKUP_DIR/SHA256SUMS" ]]
(
  cd "$BACKUP_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
N8N_BACKUP_SHA="$(sha256sum "$BACKUP_DIR/n8n-metadata.dump" | awk '{print $1}')"
echo "FRESH_PROD_H2_BACKUP=PASS path=$BACKUP_DIR n8n_metadata_sha256=$N8N_BACKUP_SHA"

# Backup must not race a runtime edit. Re-export and repeat the exact E1 drift
# guard after the backup has completed and immediately before mutation.
export_all_published "$OUTPUT_DIR/pre-after-backup/all-published.json"
for id in "$SURVIVOR_ID" "${RETIRE_IDS[@]}"; do
  export_one "$id" "$OUTPUT_DIR/pre-after-backup/published/$id.json" yes
done
for id in "${CAPTURE_IDS[@]}"; do
  export_one "$id" "$OUTPUT_DIR/pre-after-backup/current/$id.json" no
done
python3 "$ROOT/scripts/spc001-n8n-cutover-verify.py" pre \
  --e1-dir "$E1_DIR" --runtime-dir "$OUTPUT_DIR/pre-after-backup"
echo 'RUNTIME_STABLE_THROUGH_BACKUP=PASS'

SURVIVOR_IMPORT="$(prepare_import "$E1_DIR/candidate-global-api-survivor.json" "$SURVIVOR_ID")"
FINANCIAL_IMPORT="$(prepare_import "$E1_DIR/candidate-financial-api.json" "$FINANCIAL_ID")"
CONTROL_IMPORT="$(prepare_import "$E1_DIR/candidate-control-api.json" "$CONTROL_ID")"
TEXT_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-text-processor.json" "$TEXT_ID")"
PHOTO_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-photo-processor.json" "$PHOTO_ID")"
QUICK_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-quick-input.json" "$QUICK_ID")"
BOT_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-bot.json" "$BOT_ID")"
echo 'IMPORT_CANDIDATES_FROZEN_FROM_E1=PASS'

MUTATED=0
CUTOVER_COMPLETE=0
ROLLBACK_RUNNING=0

rollback_metadata() {
  local rc="$1"
  [[ "$MUTATED" -eq 1 && "$CUTOVER_COMPLETE" -eq 0 ]] || return "$rc"
  [[ "$ROLLBACK_RUNNING" -eq 0 ]] || return "$rc"
  ROLLBACK_RUNNING=1
  trap - ERR HUP INT TERM
  set +e

  echo "ROLLBACK_TRIGGERED=YES rc=$rc" | tee "$OUTPUT_DIR/rollback/rollback.txt" >&2

  (
    cd "$BACKUP_DIR"
    sha256sum -c SHA256SUMS >/dev/null
  )
  HASH_RC=$?
  echo "rollback_backup_hash_rc=$HASH_RC" >> "$OUTPUT_DIR/rollback/rollback.txt"

  if [[ "$(docker inspect "$N8N_CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" == true ]]; then
    docker stop "$N8N_CONTAINER" >/dev/null 2>&1
    STOP_RC=$?
  else
    STOP_RC=0
  fi
  echo "rollback_n8n_stop_rc=$STOP_RC" >> "$OUTPUT_DIR/rollback/rollback.txt"

  docker exec "$N8N_DB_CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U n8n -d postgres -c \
    "select pg_terminate_backend(pid) from pg_stat_activity where datname='n8n' and pid<>pg_backend_pid();" \
    >/dev/null 2>&1
  TERM_RC=$?
  docker exec "$N8N_DB_CONTAINER" dropdb -U n8n --if-exists n8n >/dev/null 2>&1
  DROP_RC=$?
  docker exec "$N8N_DB_CONTAINER" createdb -U n8n -O n8n n8n >/dev/null 2>&1
  CREATE_RC=$?
  docker exec -i "$N8N_DB_CONTAINER" pg_restore -U n8n -d n8n --exit-on-error \
    < "$BACKUP_DIR/n8n-metadata.dump" >/dev/null 2>&1
  RESTORE_RC=$?
  echo "rollback_db term=$TERM_RC drop=$DROP_RC create=$CREATE_RC restore=$RESTORE_RC" \
    >> "$OUTPUT_DIR/rollback/rollback.txt"

  docker start "$N8N_CONTAINER" >/dev/null 2>&1
  START_RC=$?
  echo "rollback_n8n_start_rc=$START_RC" >> "$OUTPUT_DIR/rollback/rollback.txt"
  wait_health >> "$OUTPUT_DIR/rollback/rollback.txt" 2>&1
  HEALTH_RC=$?

  EXPORT_RC=1
  VERIFY_RC=1
  if [[ "$HASH_RC" -eq 0 && "$DROP_RC" -eq 0 && "$CREATE_RC" -eq 0 && "$RESTORE_RC" -eq 0 && "$START_RC" -eq 0 && "$HEALTH_RC" -eq 0 ]]; then
    export_all_published "$OUTPUT_DIR/rollback/all-published.json"
    EXPORT_RC=$?
    if [[ "$EXPORT_RC" -eq 0 ]]; then
      python3 "$ROOT/scripts/spc001-n8n-cutover-verify.py" rollback \
        --e1-dir "$E1_DIR" --runtime-dir "$OUTPUT_DIR/rollback" \
        >> "$OUTPUT_DIR/rollback/rollback.txt" 2>&1
      VERIFY_RC=$?
    fi
  fi
  echo "rollback_export_rc=$EXPORT_RC rollback_verify_rc=$VERIFY_RC" \
    >> "$OUTPUT_DIR/rollback/rollback.txt"

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
  echo "SPC001_N8N_CUTOVER=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}

on_signal() {
  local sig="$1" rc=130
  [[ "$sig" == TERM ]] && rc=143
  [[ "$sig" == HUP ]] && rc=129
  trap - ERR HUP INT TERM
  rollback_metadata "$rc" || true
  echo "SPC001_N8N_CUTOVER=FAIL signal=$sig rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}

trap on_error ERR
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

# First persistent n8n mutation starts here. Quiesce all external capture ingress
# before replacing processors so caller/callee versions are never externally mixed.
MUTATED=1
unpublish_workflow "$BOT_ID"
unpublish_workflow "$QUICK_ID"
echo 'CAPTURE_INGRESS_QUIESCED=PASS'

# Remove every frozen legacy financial route owner before publishing the new
# consolidated Financial API. This avoids duplicate webhook ownership.
for id in "${RETIRE_IDS[@]}"; do
  unpublish_workflow "$id"
done
echo "LEGACY_FINANCIAL_UNPUBLISH=PASS workflows=${#RETIRE_IDS[@]}"

# /i18n and /me survive under the existing workflow identity. The frozen
# survivor candidate removes only the two replaceable financial webhook ingress.
import_workflow "$SURVIVOR_IMPORT" "$SURVIVOR_ID"
publish_workflow "$SURVIVOR_ID"
echo 'GLOBAL_SURVIVOR_CUTOVER=PASS'

# Introduce the two new Space-native API workflow IDs only after all conflicting
# legacy financial owners are no longer published.
import_workflow "$FINANCIAL_IMPORT" "$FINANCIAL_ID"
publish_workflow "$FINANCIAL_ID"
import_workflow "$CONTROL_IMPORT" "$CONTROL_ID"
publish_workflow "$CONTROL_ID"
echo 'SPACE_API_CUTOVER=PASS'

# External capture remains quiesced. Replace callees first, preserving each
# processor's pre-E1 published state, then replace/publish callers.
import_workflow "$TEXT_IMPORT" "$TEXT_ID"
if was_published_e1 "$TEXT_ID"; then publish_workflow "$TEXT_ID"; fi
import_workflow "$PHOTO_IMPORT" "$PHOTO_ID"
if was_published_e1 "$PHOTO_ID"; then publish_workflow "$PHOTO_ID"; fi

echo 'VOICE_PROCESSOR_MUTATION=NONE'

import_workflow "$QUICK_IMPORT" "$QUICK_ID"
publish_workflow "$QUICK_ID"
import_workflow "$BOT_IMPORT" "$BOT_ID"
publish_workflow "$BOT_ID"
echo 'CAPTURE_CUTOVER=PASS'

docker restart "$N8N_CONTAINER" >/dev/null
wait_health

# Verify the actual saved/published runtime, not merely the frozen candidates.
export_all_published "$OUTPUT_DIR/post/all-published.json"
for id in "$SURVIVOR_ID" "$FINANCIAL_ID" "$CONTROL_ID" "${CAPTURE_IDS[@]}"; do
  export_one "$id" "$OUTPUT_DIR/post/current/$id.json" no
done
python3 "$ROOT/scripts/spc001-n8n-cutover-verify.py" post \
  --e1-dir "$E1_DIR" --runtime-dir "$OUTPUT_DIR/post" \
  | tee "$OUTPUT_DIR/post/runtime-verify.txt"

python3 "$ROOT/scripts/spc001-audit-workflow-tenancy.py" --reachable-only \
  "$OUTPUT_DIR/post/current/$QUICK_ID.json" \
  "$OUTPUT_DIR/post/current/$TEXT_ID.json" \
  "$OUTPUT_DIR/post/current/$VOICE_ID.json" \
  "$OUTPUT_DIR/post/current/$PHOTO_ID.json" \
  "$OUTPUT_DIR/post/current/$BOT_ID.json" \
  "$OUTPUT_DIR/post/current/$FINANCIAL_ID.json" \
  "$OUTPUT_DIR/post/current/$CONTROL_ID.json" \
  "$OUTPUT_DIR/post/current/$SURVIVOR_ID.json" \
  | tee "$OUTPUT_DIR/post/tenancy-audit.txt"
grep -Fx 'SPC001_TENANCY_AUDIT=PASS' "$OUTPUT_DIR/post/tenancy-audit.txt" >/dev/null
echo 'APPLIED_TENANCY_AUDIT=PASS'

# E2 never writes MoneyTrack DB. Re-run only strict read-only 315 after n8n
# cutover to prove the already-migrated live state remains valid.
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init
ux022_db_psql_file "$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql" \
  2>&1 | tee "$OUTPUT_DIR/post/live-315.txt"
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$OUTPUT_DIR/post/live-315.txt" >/dev/null
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=END' "$OUTPUT_DIR/post/live-315.txt" >/dev/null
echo 'LIVE_315_AFTER_N8N_CUTOVER=PASS'

CUTOVER_COMPLETE=1
trap - ERR HUP INT TERM

D3_COMMIT_SHA="$(awk -F= '/^D3_COMMIT_BUNDLE_SHA256=/{print $2}' "$E1_METADATA" | tail -n1)"
D3_ROLLBACK_SHA="$(awk -F= '/^D3_ROLLBACK_BUNDLE_SHA256=/{print $2}' "$E1_METADATA" | tail -n1)"
E1_SOURCE_HEAD="$(python3 - "$E1_PLAN" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8'))['source_head'])
PY
)"

{
  echo "HEAD=$HEAD_SHA"
  echo "E1_SOURCE_HEAD=$E1_SOURCE_HEAD"
  echo "E1_EVIDENCE_DIR=$E1_DIR"
  echo "E1_SHA256SUMS_SHA256=$E1_MANIFEST_SHA"
  echo "D3_COMMIT_BUNDLE_SHA256=$D3_COMMIT_SHA"
  echo "D3_ROLLBACK_BUNDLE_SHA256=$D3_ROLLBACK_SHA"
  echo "FRESH_BACKUP_DIR=$BACKUP_DIR"
  echo "N8N_METADATA_BACKUP_SHA256=$N8N_BACKUP_SHA"
  echo "GLOBAL_SURVIVOR_WORKFLOW_ID=$SURVIVOR_ID"
  echo "LEGACY_FINANCIAL_RETIRE_WORKFLOW_COUNT=${#RETIRE_IDS[@]}"
  echo "FINANCIAL_WORKFLOW_ID=$FINANCIAL_ID"
  echo "CONTROL_WORKFLOW_ID=$CONTROL_ID"
  echo "CAPTURE_UPDATED=$TEXT_ID,$PHOTO_ID,$QUICK_ID,$BOT_ID"
  echo "VOICE_PROCESSOR_MUTATION=NONE"
  echo "DB_MUTATION=NONE"
  echo "N8N_MUTATION=CUTOVER_APPLIED"
  echo "N8N_ROLLBACK=NOT_REQUIRED"
  echo "LIVE_315_AFTER_N8N_CUTOVER=PASS"
  echo "PREVIEW_MUTATION=NONE"
  echo "PRODUCTION_FRONTEND_MUTATION=NONE"
  echo "SPC001_N8N_CUTOVER=PASS"
} > "$OUTPUT_DIR/cutover-metadata.txt"

# Outer evidence manifest references the large fresh backup via the backup's own
# verified manifest instead of re-hashing all dump payloads a second time.
python3 - "$OUTPUT_DIR" "$BACKUP_DIR" <<'PY'
from pathlib import Path
import hashlib, sys
root=Path(sys.argv[1]).resolve()
backup=Path(sys.argv[2]).resolve()
manifest=root/'SHA256SUMS'

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):
            h.update(chunk)
    return h.hexdigest()

lines=[]
for p in sorted(root.rglob('*')):
    if not p.is_file() or p==manifest or backup in p.parents:
        continue
    lines.append(f"{sha(p)}  {p.relative_to(root)}\n")
for p in (backup/'SHA256SUMS', backup/'COMPLETE'):
    lines.append(f"{sha(p)}  {p.relative_to(root)}\n")
manifest.write_text(''.join(lines),encoding='utf-8')
PY
sync

echo "E2_EVIDENCE_DIR=$OUTPUT_DIR"
echo "FRESH_BACKUP_DIR=$BACKUP_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=CUTOVER_APPLIED'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'SPC001_N8N_CUTOVER=PASS'
