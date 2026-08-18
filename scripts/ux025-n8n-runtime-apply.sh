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

for cmd in git docker python3 sha256sum find grep awk curl sync sed; do
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
DB_EVIDENCE_HEAD="$(sed -n 's/^HEAD=//p' "$DB_EVIDENCE/db-metadata.txt" | head -n1)"
[[ -n "$DB_EVIDENCE_HEAD" ]] || { echo 'UX025_N8N_APPLY=FAIL db_evidence_head_missing' >&2; exit 1; }
grep -Fx 'LIVE_DB_POST_VERIFY=PASS' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
grep -Fx 'UX025_DB_APPLY=PASS' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
grep -Fx 'N8N_MUTATION=NONE' "$DB_EVIDENCE/db-metadata.txt" >/dev/null

# Source-only recovery commits after an accepted DB apply may reuse that DB
# evidence only when the evidence HEAD is an ancestor and every DB-affecting
# UX-025 source remains byte-identical across the range.
git merge-base --is-ancestor "$DB_EVIDENCE_HEAD" "$HEAD_SHA" || {
  echo "UX025_N8N_APPLY=FAIL db_evidence_not_ancestor evidence=$DB_EVIDENCE_HEAD head=$HEAD_SHA" >&2
  exit 1
}
DB_RELEVANT=(
  db/domain/UX-025
  scripts/ux025-build-db-bundle.py
  scripts/ux025-db-runtime-apply.sh
)
if ! git diff --quiet "$DB_EVIDENCE_HEAD" "$HEAD_SHA" -- "${DB_RELEVANT[@]}"; then
  echo "UX025_N8N_APPLY=FAIL db_source_changed_since_evidence evidence=$DB_EVIDENCE_HEAD head=$HEAD_SHA" >&2
  git diff --name-only "$DB_EVIDENCE_HEAD" "$HEAD_SHA" -- "${DB_RELEVANT[@]}" >&2
  exit 1
fi
echo "UX025_DB_EVIDENCE=PASS evidence_head=$DB_EVIDENCE_HEAD current_head=$HEAD_SHA"

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
PRE_VERIFY_LOG="$OUTPUT_DIR/financial.before.verify.log"
ROLLBACK_SECURED="$OUTPUT_DIR/financial.rollback.secured.json"
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
  # docker cp writes the container-side file as root on this runtime. Always
  # clean and normalize that staging path as root before invoking n8n as its
  # normal container user; otherwise chmod can fail before import starts.
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" chmod 0644 "$remote"
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$WORKFLOW_ID" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
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

# Preserve the actual pre-state for forensics. It may contain the SEC-001 gap
# discovered during recovery, so observe its protection state without ever
# treating GAP as accepted protection or using this export for rollback.
export_workflow "$OLD_CURRENT" current
export_workflow "$OLD_PUBLISHED" published
python3 scripts/ux025-verify-financial-workflow.py \
  --input "$OLD_PUBLISHED" \
  --expected spc \
  --protection observe >"$PRE_VERIFY_LOG"
cat "$PRE_VERIFY_LOG"
PRE_SHA="$(sha256sum "$OLD_PUBLISHED" | awk '{print $1}')"
if grep -Fq 'UX025_FINANCIAL_SEC001_PROTECTION=PASS' "$PRE_VERIFY_LOG"; then
  PRE_SEC001_PROTECTION=PASS
  SEC001_REPAIR=PRESERVED
else
  grep -Fq 'UX025_FINANCIAL_SEC001_PROTECTION=GAP' "$PRE_VERIFY_LOG" || {
    echo 'UX025_N8N_APPLY=FAIL pre_protection_state_unknown' >&2
    exit 1
  }
  PRE_SEC001_PROTECTION=GAP
  SEC001_REPAIR=APPLIED
fi
echo "UX025_PRE_CUTOVER_WORKFLOW=PASS sha256=$PRE_SHA sec001=$PRE_SEC001_PROTECTION"

# Rollback is generated from accepted SPC source and protected before mutation.
# Never roll back to the forensic export when that export is unprotected.
python3 scripts/ux025-generate-financial-api.py --mode spc-secured --output "$ROLLBACK_SECURED"
python3 scripts/ux025-verify-financial-workflow.py --input "$ROLLBACK_SECURED" --expected spc
ROLLBACK_SHA="$(sha256sum "$ROLLBACK_SECURED" | awk '{print $1}')"
echo "UX025_SECURED_ROLLBACK_CANDIDATE=PASS sha256=$ROLLBACK_SHA"

python3 scripts/ux025-generate-financial-api.py --mode ux025 --output "$CANDIDATE"
python3 scripts/ux025-verify-financial-workflow.py --input "$CANDIDATE" --expected ux025
CANDIDATE_SHA="$(sha256sum "$CANDIDATE" | awk '{print $1}')"
echo "UX025_N8N_CANDIDATE=PASS sha256=$CANDIDATE_SHA"

MUTATED=0
rollback() {
  local rc=$?
  trap - ERR
  if [[ "$MUTATED" -eq 1 ]]; then
    echo 'UX025_N8N_ROLLBACK_TRIGGERED=YES' >&2
    if import_publish "$ROLLBACK_SECURED" \
      && n8n_health \
      && export_workflow "$OUTPUT_DIR/financial.rollback.published.json" published \
      && python3 scripts/ux025-verify-financial-workflow.py --input "$OUTPUT_DIR/financial.rollback.published.json" --expected spc; then
      echo 'UX025_N8N_WORKFLOW_ROLLBACK=PASS secured_spc=YES' >&2
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
  echo "DB_EVIDENCE_HEAD=$DB_EVIDENCE_HEAD"
  echo "PRE_PUBLISHED_SHA256=$PRE_SHA"
  echo "PRE_SEC001_PROTECTION=$PRE_SEC001_PROTECTION"
  echo "SEC001_REPAIR=$SEC001_REPAIR"
  echo "ROLLBACK_SECURED_SHA256=$ROLLBACK_SHA"
  echo "CANDIDATE_SHA256=$CANDIDATE_SHA"
  echo "POST_PUBLISHED_SHA256=$POST_SHA"
  echo "BACKUP_DIR=$N8N_BACKUP_DIR"
  echo 'PRE_ROUTE_COUNT=30'
  echo 'POST_ROUTE_COUNT=33'
  echo 'ROLLBACK_CANDIDATE_SEC001=PASS'
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
