#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXPECTED_HEAD=""
E1_DIR=""
BACKUP_DIR=""
OUTPUT_DIR=""
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
N8N_DB_CONTAINER="${N8N_DB_CONTAINER:-postgres}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --e1-dir) E1_DIR="${2:-}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$EXPECTED_HEAD" && -n "$E1_DIR" && -n "$BACKUP_DIR" && -n "$OUTPUT_DIR" ]] || {
  echo 'SPC001_N8N_IMPORT_REHEARSAL=REFUSED required_args_missing' >&2
  exit 2
}
[[ "$E1_DIR" = /* && "$BACKUP_DIR" = /* && "$OUTPUT_DIR" = /* ]] || {
  echo 'SPC001_N8N_IMPORT_REHEARSAL=REFUSED absolute_paths_required' >&2
  exit 2
}
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'SPC001_N8N_IMPORT_REHEARSAL=REFUSED durable_output_required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git docker python3 sha256sum awk grep; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing command $cmd" >&2; exit 1; }
done
[[ -z "$(git status --porcelain)" ]] || { echo 'ERROR: dirty checkout' >&2; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "ERROR: head mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}

for c in "$N8N_CONTAINER" "$N8N_DB_CONTAINER"; do
  docker inspect "$c" >/dev/null 2>&1 || { echo "ERROR: missing container $c" >&2; exit 1; }
done
[[ "$(docker inspect "$N8N_CONTAINER" --format '{{.State.Running}}')" == true ]] || {
  echo 'ERROR: production n8n not running' >&2
  exit 1
}

# Prove the running n8n container uses the standard PostgreSQL database selector
# that this rehearsal overrides per CLI process. No secret value is printed.
docker inspect "$N8N_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -Fx 'DB_TYPE=postgresdb' >/dev/null
docker inspect "$N8N_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -Eq '^DB_POSTGRESDB_DATABASE=.+' >/dev/null
echo 'N8N_CLONE_DB_ENV_OVERRIDE_CONTRACT=PASS'

for f in \
  "$E1_DIR/SHA256SUMS" \
  "$E1_DIR/preflight-metadata.txt" \
  "$E1_DIR/cutover-plan.json" \
  "$BACKUP_DIR/SHA256SUMS" \
  "$BACKUP_DIR/n8n-metadata.dump"; do
  [[ -s "$f" ]] || { echo "ERROR: evidence missing_or_empty $f" >&2; exit 1; }
done
# COMPLETE is intentionally created with `touch` by prod-h2-backup-now.sh.
# Its contract is existence, not non-zero size.
[[ -f "$BACKUP_DIR/COMPLETE" ]] || {
  echo "ERROR: backup COMPLETE marker missing $BACKUP_DIR/COMPLETE" >&2
  exit 1
}
echo 'BACKUP_COMPLETE_MARKER=PASS'
(
  cd "$E1_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
(
  cd "$BACKUP_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
grep -Fx 'SPC001_N8N_CUTOVER_PREFLIGHT=PASS' "$E1_DIR/preflight-metadata.txt" >/dev/null
echo 'REHEARSAL_INPUT_EVIDENCE=PASS'

umask 077
mkdir -p "$OUTPUT_DIR/import" "$OUTPUT_DIR/post/current"
chmod 700 "$OUTPUT_DIR"

CLONE_DB="spc001_n8n_rehearsal_${HEAD_SHA:0:8}_$$_${RANDOM}"
CLONE_CREATED=0
REMOTE_FILES=()

cleanup() {
  local rc=$?
  trap - EXIT
  for remote in "${REMOTE_FILES[@]}"; do
    docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  done
  if [[ "$CLONE_CREATED" -eq 1 ]]; then
    docker exec "$N8N_DB_CONTAINER" psql -X -q -U n8n -d postgres -c \
      "select pg_terminate_backend(pid) from pg_stat_activity where datname='$CLONE_DB' and pid<>pg_backend_pid();" \
      >/dev/null 2>&1 || true
    docker exec "$N8N_DB_CONTAINER" dropdb -U n8n --if-exists "$CLONE_DB" >/dev/null 2>&1 || true
    CLONE_CREATED=0
  fi
  echo "CLONE_DROPPED=YES" | tee -a "$OUTPUT_DIR/rehearsal.txt"
  if [[ "$rc" -ne 0 ]]; then
    echo "SPC001_N8N_IMPORT_REHEARSAL=FAIL rc=$rc" | tee -a "$OUTPUT_DIR/rehearsal.txt" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT

STALE="$(docker exec "$N8N_DB_CONTAINER" psql -X -q -At -U n8n -d postgres -c \
  "select datname from pg_database where datname like 'spc001_n8n_rehearsal_%' order by datname;")"
[[ -z "$STALE" ]] || { echo "ERROR: stale rehearsal DB(s): $STALE" >&2; exit 1; }

docker exec "$N8N_DB_CONTAINER" createdb -U n8n -O n8n "$CLONE_DB"
CLONE_CREATED=1
docker exec -i "$N8N_DB_CONTAINER" pg_restore -U n8n -d "$CLONE_DB" --exit-on-error --single-transaction \
  < "$BACKUP_DIR/n8n-metadata.dump"
echo "CLONE_RESTORE=PASS db=$CLONE_DB" | tee "$OUTPUT_DIR/rehearsal.txt"

n8n_clone() {
  local log="$1"
  shift
  echo "+ n8n $*" >> "$log"
  docker exec -e DB_POSTGRESDB_DATABASE="$CLONE_DB" "$N8N_CONTAINER" n8n "$@" >> "$log" 2>&1
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

import_clone() {
  local file="$1"
  local id="$2"
  local log="$OUTPUT_DIR/import-$id.log"
  local remote="/tmp/spc001-e2r-${id}-$$.json"
  REMOTE_FILES+=("$remote")
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  if ! n8n_clone "$log" import:workflow --input="$remote"; then
    echo "CLONE_IMPORT=FAIL id=$id log=$log" | tee -a "$OUTPUT_DIR/rehearsal.txt" >&2
    cat "$log" >&2
    return 1
  fi
  echo "CLONE_IMPORT=PASS id=$id" | tee -a "$OUTPUT_DIR/rehearsal.txt"
}

publish_clone() {
  local id="$1"
  local log="$OUTPUT_DIR/publish-$id.log"
  if ! n8n_clone "$log" publish:workflow --id="$id"; then
    echo "CLONE_PUBLISH=FAIL id=$id log=$log" | tee -a "$OUTPUT_DIR/rehearsal.txt" >&2
    cat "$log" >&2
    return 1
  fi
  echo "CLONE_PUBLISH=PASS id=$id" | tee -a "$OUTPUT_DIR/rehearsal.txt"
}

unpublish_clone() {
  local id="$1"
  local log="$OUTPUT_DIR/unpublish-$id.log"
  if ! n8n_clone "$log" unpublish:workflow --id="$id"; then
    echo "CLONE_UNPUBLISH=FAIL id=$id log=$log" | tee -a "$OUTPUT_DIR/rehearsal.txt" >&2
    cat "$log" >&2
    return 1
  fi
  echo "CLONE_UNPUBLISH=PASS id=$id" | tee -a "$OUTPUT_DIR/rehearsal.txt"
}

export_clone_one() {
  local id="$1"
  local out="$2"
  local remote="/tmp/spc001-e2r-export-${id}-$$.json"
  REMOTE_FILES+=("$remote")
  n8n_clone "$OUTPUT_DIR/export-$id.log" export:workflow --id="$id" --output="$remote"
  docker cp "$N8N_CONTAINER:$remote" "$out" >/dev/null
  [[ -s "$out" ]]
}

export_clone_all_published() {
  local out="$1"
  local remote="/tmp/spc001-e2r-all-$$.json"
  REMOTE_FILES+=("$remote")
  n8n_clone "$OUTPUT_DIR/export-all-published.log" export:workflow --all --published --output="$remote"
  docker cp "$N8N_CONTAINER:$remote" "$out" >/dev/null
  [[ -s "$out" ]]
}

PLAN="$E1_DIR/cutover-plan.json"
mapfile -t RETIRE_IDS < <(python3 - "$PLAN" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
for x in p['legacy_financial_retire_workflow_ids']: print(x)
PY
)
SURVIVOR_ID='7TJ2xQTxLsTydXZc'
FINANCIAL_ID='SPC001FinancialApi202608'
CONTROL_ID='SPC001ControlApi202608'
BOT_ID='DER2Lc3dT2afyQhy'
QUICK_ID='UX022QuickInput202608'
TEXT_ID='f5ioJKyPTupUMV9h'
VOICE_ID='Td7kvvrtqQK0FTJg'
PHOTO_ID='5VC0EcFB21rwTfoI'

SURVIVOR_IMPORT="$(prepare_import "$E1_DIR/candidate-global-api-survivor.json" "$SURVIVOR_ID")"
FINANCIAL_IMPORT="$(prepare_import "$E1_DIR/candidate-financial-api.json" "$FINANCIAL_ID")"
CONTROL_IMPORT="$(prepare_import "$E1_DIR/candidate-control-api.json" "$CONTROL_ID")"
TEXT_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-text-processor.json" "$TEXT_ID")"
PHOTO_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-photo-processor.json" "$PHOTO_ID")"
QUICK_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-quick-input.json" "$QUICK_ID")"
BOT_IMPORT="$(prepare_import "$E1_DIR/forensic/candidate-bot.json" "$BOT_ID")"

# Rehearse the exact metadata mutation order from E2, entirely in the clone DB.
unpublish_clone "$BOT_ID"
unpublish_clone "$QUICK_ID"
for id in "${RETIRE_IDS[@]}"; do unpublish_clone "$id"; done

import_clone "$SURVIVOR_IMPORT" "$SURVIVOR_ID"
publish_clone "$SURVIVOR_ID"
import_clone "$FINANCIAL_IMPORT" "$FINANCIAL_ID"
publish_clone "$FINANCIAL_ID"
import_clone "$CONTROL_IMPORT" "$CONTROL_ID"
publish_clone "$CONTROL_ID"

import_clone "$TEXT_IMPORT" "$TEXT_ID"
if python3 - "$E1_DIR/all-published.json" "$TEXT_ID" <<'PY'
import json,sys
raw=json.load(open(sys.argv[1],encoding='utf-8'))
if isinstance(raw,dict): raw=[raw]
raise SystemExit(0 if any(str(x.get('id') or '')==sys.argv[2] for x in raw) else 1)
PY
then publish_clone "$TEXT_ID"; fi

import_clone "$PHOTO_IMPORT" "$PHOTO_ID"
if python3 - "$E1_DIR/all-published.json" "$PHOTO_ID" <<'PY'
import json,sys
raw=json.load(open(sys.argv[1],encoding='utf-8'))
if isinstance(raw,dict): raw=[raw]
raise SystemExit(0 if any(str(x.get('id') or '')==sys.argv[2] for x in raw) else 1)
PY
then publish_clone "$PHOTO_ID"; fi

echo 'CLONE_VOICE_PROCESSOR_MUTATION=NONE' | tee -a "$OUTPUT_DIR/rehearsal.txt"
import_clone "$QUICK_IMPORT" "$QUICK_ID"
publish_clone "$QUICK_ID"
import_clone "$BOT_IMPORT" "$BOT_ID"
publish_clone "$BOT_ID"

export_clone_all_published "$OUTPUT_DIR/post/all-published.json"
for id in "$SURVIVOR_ID" "$FINANCIAL_ID" "$CONTROL_ID" "$BOT_ID" "$QUICK_ID" "$TEXT_ID" "$VOICE_ID" "$PHOTO_ID"; do
  export_clone_one "$id" "$OUTPUT_DIR/post/current/$id.json"
done
python3 "$ROOT/scripts/spc001-n8n-cutover-verify.py" post --e1-dir "$E1_DIR" --runtime-dir "$OUTPUT_DIR/post" \
  | tee -a "$OUTPUT_DIR/rehearsal.txt"

echo 'CLONE_METADATA_CUTOVER=PASS' | tee -a "$OUTPUT_DIR/rehearsal.txt"
echo 'PRODUCTION_N8N_METADATA_MUTATION=NONE' | tee -a "$OUTPUT_DIR/rehearsal.txt"
echo 'MONEYTRACK_DB_MUTATION=NONE' | tee -a "$OUTPUT_DIR/rehearsal.txt"
echo 'SPC001_N8N_IMPORT_REHEARSAL=PASS' | tee -a "$OUTPUT_DIR/rehearsal.txt"

python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); manifest=root/'SHA256SUMS'
lines=[]
for p in sorted(root.rglob('*')):
    if p.is_file() and p!=manifest:
        h=hashlib.sha256(p.read_bytes()).hexdigest()
        lines.append(f'{h}  {p.relative_to(root)}\n')
manifest.write_text(''.join(lines),encoding='utf-8')
PY
sync
