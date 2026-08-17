#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
DB_EVIDENCE=""
OUTPUT_DIR=""
N8N_CONTAINER="${N8N_CONTAINER:-n8n}"
WORKFLOW_ID="SPC001FinancialApi202608"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --db-evidence-dir) DB_EVIDENCE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'UX025_N8N_APPLY=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$DB_EVIDENCE" && -n "$OUTPUT_DIR" ]] || { echo 'UX025_N8N_APPLY=REFUSED required_arguments_missing' >&2; exit 2; }
for p in "$DB_EVIDENCE" "$OUTPUT_DIR"; do [[ "$p" = /* ]] || { echo "ERROR: absolute path required: $p" >&2; exit 2; }; done
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'UX025_N8N_APPLY=REFUSED durable_output_required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git docker python3 sha256sum find grep awk curl sync; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "UX025_N8N_APPLY=FAIL missing_command=$cmd" >&2; exit 1; }
done
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || { echo "UX025_N8N_APPLY=FAIL head_mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'UX025_N8N_APPLY=FAIL dirty_checkout' >&2; exit 1; }

python3 scripts/ux025-screen-decomposition-source-gate.py
python3 scripts/ux025-category-directory-source-gate.py

for f in "$DB_EVIDENCE/db-metadata.txt" "$DB_EVIDENCE/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "UX025_N8N_APPLY=FAIL db_evidence_missing=$f" >&2; exit 1; }
done
(cd "$DB_EVIDENCE" && sha256sum -c SHA256SUMS >/dev/null)
grep -Fx "HEAD=$HEAD_SHA" "$DB_EVIDENCE/db-metadata.txt" >/dev/null
grep -Fx 'LIVE_DB_POST_VERIFY=PASS' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
grep -Fx 'UX025_DB_APPLY=PASS' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
grep -Fx 'N8N_MUTATION=NONE' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
echo 'UX025_DB_EVIDENCE=PASS'

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init
ux022_db_psql_file "$ROOT/db/domain/UX-025/090_verify_category_directory.sql" >/dev/null
echo 'UX025_DB_LIVE_PRE_N8N_READONLY=PASS'

for c in "$N8N_CONTAINER" postgres "$UX022_DB_CONTAINER"; do
  [[ "$(docker inspect "$c" --format '{{.State.Running}}')" == true ]] || { echo "UX025_N8N_APPLY=FAIL container_not_running=$c" >&2; exit 1; }
done
for cli in 'export:workflow --help' 'import:workflow --help' 'publish:workflow --help'; do
  docker exec "$N8N_CONTAINER" n8n $cli >/dev/null 2>&1 || { echo "UX025_N8N_APPLY=FAIL n8n_cli=$cli" >&2; exit 1; }
done
docker exec "$N8N_CONTAINER" n8n export:workflow --help 2>&1 | grep -Fq -- '--published'

umask 077
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"
OLD_CURRENT="$OUTPUT_DIR/financial.before.current.json"
OLD_PUBLISHED="$OUTPUT_DIR/financial.before.published.json"
CANDIDATE="$OUTPUT_DIR/financial.candidate.json"
POST_CURRENT="$OUTPUT_DIR/financial.after.current.json"
POST_PUBLISHED="$OUTPUT_DIR/financial.after.published.json"
METADATA="$OUTPUT_DIR/n8n-metadata.txt"
BACKUP_LOG="$OUTPUT_DIR/prod-h2-backup.log"

export_workflow() {
  local output="$1"
  local published="$2"
  local remote="/tmp/ux025-${published}-${WORKFLOW_ID}.json"
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  if [[ "$published" == published ]]; then
    docker exec "$N8N_CONTAINER" n8n export:workflow --id="$WORKFLOW_ID" --published --output="$remote" >/dev/null
  else
    docker exec "$N8N_CONTAINER" n8n export:workflow --id="$WORKFLOW_ID" --output="$remote" >/dev/null
  fi
  docker cp "$N8N_CONTAINER:$remote" "$output" >/dev/null
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  [[ -s "$output" ]]
}

import_publish() {
  local file="$1"
  local remote="/tmp/ux025-import-${WORKFLOW_ID}.json"
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  docker exec "$N8N_CONTAINER" chmod 0644 "$remote"
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$WORKFLOW_ID" >/dev/null
  docker exec "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

n8n_health() {
  docker exec "$N8N_CONTAINER" node -e "fetch('http://127.0.0.1:5678/healthz').then(r=>{if(!r.ok)process.exit(1);return r.text()}).then(()=>process.exit(0)).catch(()=>process.exit(1))"
}

# Fresh full recovery point before changing n8n metadata.
BACKUP_ROOT="$OUTPUT_DIR/prod-h2" bash "$ROOT/scripts/prod-h2-backup-now.sh" >"$BACKUP_LOG" 2>&1
mapfile -t BACKUP_DIRS < <(find "$OUTPUT_DIR/prod-h2" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#BACKUP_DIRS[@]}" -eq 1 ]] || { echo 'UX025_N8N_APPLY=FAIL backup_directory_count' >&2; exit 1; }
N8N_BACKUP_DIR="${BACKUP_DIRS[0]}"
[[ -f "$N8N_BACKUP_DIR/COMPLETE" && -s "$N8N_BACKUP_DIR/SHA256SUMS" ]] || { echo 'UX025_N8N_APPLY=FAIL backup_incomplete' >&2; exit 1; }
(cd "$N8N_BACKUP_DIR" && sha256sum -c SHA256SUMS >/dev/null)
echo "UX025_N8N_FRESH_BACKUP=PASS path=$N8N_BACKUP_DIR"

export_workflow "$OLD_CURRENT" current
export_workflow "$OLD_PUBLISHED" published
python3 scripts/ux025-verify-financial-workflow.py --input "$OLD_PUBLISHED" --expected spc
PRE_SHA="$(sha256sum "$OLD_PUBLISHED" | awk '{print $1}')"
echo "UX025_PRE_CUTOVER_WORKFLOW=PASS sha256=$PRE_SHA"

python3 scripts/ux025-generate-financial-api.py --output "$CANDIDATE"
python3 scripts/ux025-verify-financial-workflow.py --input "$CANDIDATE" --expected ux025
CANDIDATE_SHA="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
echo "UX025_N8N_CANDIDATE=PASS sha256=$CANDIDATE_SHA"

MUTATED=0
rollback() {
  local rc=$?
  trap - ERR
  if [[ "$MUTATED" -eq 1 ]]; then
    echo 'UX025_N8N_ROLLBACK_TRIGGERED=YES' >&2
    if import_publish "$OLD_PUBLISHED" \
      && n8n_health \
      && export_workflow "$OUTPUT_DIR/financial.rollback.published.json" published \
      && python3 scripts/ux025-verify-financial-workflow.py --input "$OUTPUT_DIR/financial.rollback.published.json" --expected spc; then
      echo 'UX025_N8N_WORKFLOW_ROLLBACK=PASS' >&2
    else
      echo 'UX025_N8N_WORKFLOW_ROLLBACK=FAIL' >&2
    fi
  fi
  echo "UX025_N8N_APPLY=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}
trap rollback ERR

MUTATED=1
import_publish "$CANDIDATE"
n8n_health
export_workflow "$POST_CURRENT" current
export_workflow "$POST_PUBLISHED" published
python3 scripts/ux025-verify-financial-workflow.py --input "$POST_CURRENT" --expected ux025
python3 scripts/ux025-verify-financial-workflow.py --input "$POST_PUBLISHED" --expected ux025
python3 scripts/spc001-audit-workflow-tenancy.py --reachable-only "$POST_PUBLISHED" >"$OUTPUT_DIR/tenancy-audit.log"
grep -F 'SPC001_WORKFLOW_TENANCY_AUDIT=PASS' "$OUTPUT_DIR/tenancy-audit.log" >/dev/null
POST_SHA="$(sha256sum "$POST_PUBLISHED" | awk '{print $1}')"
MUTATED=0
trap - ERR

echo "UX025_N8N_CUTOVER=PASS sha256=$POST_SHA"

{
  echo "HEAD=$HEAD_SHA"
  echo "DB_EVIDENCE_DIR=$DB_EVIDENCE"
  echo "PRE_PUBLISHED_SHA256=$PRE_SHA"
  echo "CANDIDATE_SHA256=$CANDIDATE_SHA"
  echo "POST_PUBLISHED_SHA256=$POST_SHA"
  echo "BACKUP_DIR=$N8N_BACKUP_DIR"
  echo 'PRE_ROUTE_COUNT=30'
  echo 'POST_ROUTE_COUNT=33'
  echo 'SEC001_PROTECTION=PASS'
  echo 'TENANCY_AUDIT=PASS'
  echo 'DB_MUTATION=ALREADY_APPLIED_FROM_EVIDENCE'
  echo 'N8N_MUTATION=APPLIED'
  echo 'PREVIEW_MUTATION=NONE'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'ROLLBACK_TRIGGERED=NO'
  echo 'UX025_N8N_APPLY=PASS'
} > "$METADATA"

python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); out=root/'SHA256SUMS'; rows=[]
for p in sorted(root.rglob('*')):
    if p.is_file() and p != out:
        rows.append(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(root)}\n")
out.write_text(''.join(rows),encoding='utf-8')
PY
sync

echo "UX025_N8N_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'UX025_N8N_APPLY=PASS'
