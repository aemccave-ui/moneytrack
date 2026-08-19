#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
DB_EVIDENCE=""
N8N_EVIDENCE=""
OUTPUT_DIR=""
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --db-evidence-dir) DB_EVIDENCE="${2:-}"; shift 2 ;;
    --n8n-evidence-dir) N8N_EVIDENCE="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'UX025_PREVIEW_APPLY=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$DB_EVIDENCE" && -n "$N8N_EVIDENCE" && -n "$OUTPUT_DIR" ]] || {
  echo 'UX025_PREVIEW_APPLY=REFUSED required_arguments_missing' >&2
  exit 2
}
for p in "$DB_EVIDENCE" "$N8N_EVIDENCE" "$OUTPUT_DIR" "$PREVIEW_ROOT"; do
  [[ "$p" = /* ]] || { echo "ERROR: absolute path required: $p" >&2; exit 2; }
done
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'UX025_PREVIEW_APPLY=REFUSED durable_output_required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git npm rsync curl tar sha256sum grep awk sort mktemp tee python3 sync sed; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "UX025_PREVIEW_APPLY=FAIL missing_command=$cmd" >&2; exit 1; }
done

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "UX025_PREVIEW_APPLY=FAIL head_mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || { echo 'UX025_PREVIEW_APPLY=FAIL dirty_checkout' >&2; exit 1; }

# Accepted DB evidence remains valid only while DB-affecting UX-025 source is unchanged.
for f in "$DB_EVIDENCE/db-metadata.txt" "$DB_EVIDENCE/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "UX025_PREVIEW_APPLY=FAIL db_evidence_missing=$f" >&2; exit 1; }
done
(cd "$DB_EVIDENCE" && sha256sum -c SHA256SUMS >/dev/null)
DB_EVIDENCE_HEAD="$(sed -n 's/^HEAD=//p' "$DB_EVIDENCE/db-metadata.txt" | head -n1)"
[[ "$DB_EVIDENCE_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo 'UX025_PREVIEW_APPLY=FAIL db_evidence_head_invalid' >&2; exit 1; }
grep -Fx 'LIVE_DB_POST_VERIFY=PASS' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
grep -Fx 'UX025_DB_APPLY=PASS' "$DB_EVIDENCE/db-metadata.txt" >/dev/null
git merge-base --is-ancestor "$DB_EVIDENCE_HEAD" "$HEAD_SHA" || {
  echo "UX025_PREVIEW_APPLY=FAIL db_evidence_not_ancestor evidence=$DB_EVIDENCE_HEAD head=$HEAD_SHA" >&2
  exit 1
}
DB_RELEVANT=(
  db/domain/UX-025
  scripts/ux025-build-db-bundle.py
  scripts/ux025-db-runtime-apply.sh
)
if ! git diff --quiet "$DB_EVIDENCE_HEAD" "$HEAD_SHA" -- "${DB_RELEVANT[@]}"; then
  echo 'UX025_PREVIEW_APPLY=FAIL db_source_changed_since_evidence' >&2
  git diff --name-only "$DB_EVIDENCE_HEAD" "$HEAD_SHA" -- "${DB_RELEVANT[@]}" >&2
  exit 1
fi
echo "UX025_DB_EVIDENCE=PASS evidence_head=$DB_EVIDENCE_HEAD current_head=$HEAD_SHA"

# Accepted n8n evidence may be reused by later frontend/deploy-only commits only
# when every n8n/backend-affecting source remains byte-identical.
for f in "$N8N_EVIDENCE/n8n-metadata.txt" "$N8N_EVIDENCE/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "UX025_PREVIEW_APPLY=FAIL n8n_evidence_missing=$f" >&2; exit 1; }
done
(cd "$N8N_EVIDENCE" && sha256sum -c SHA256SUMS >/dev/null)
N8N_EVIDENCE_HEAD="$(sed -n 's/^HEAD=//p' "$N8N_EVIDENCE/n8n-metadata.txt" | head -n1)"
[[ "$N8N_EVIDENCE_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo 'UX025_PREVIEW_APPLY=FAIL n8n_evidence_head_invalid' >&2; exit 1; }
grep -Fx "DB_EVIDENCE_DIR=$DB_EVIDENCE" "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'POST_ROUTE_COUNT=33' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'SEC001_PROTECTION=PASS' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'TENANCY_AUDIT=PASS' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'N8N_MUTATION=APPLIED' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'PREVIEW_MUTATION=NONE' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'PRODUCTION_FRONTEND_MUTATION=NONE' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'ROLLBACK_TRIGGERED=NO' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
grep -Fx 'UX025_N8N_APPLY=PASS' "$N8N_EVIDENCE/n8n-metadata.txt" >/dev/null
git merge-base --is-ancestor "$N8N_EVIDENCE_HEAD" "$HEAD_SHA" || {
  echo "UX025_PREVIEW_APPLY=FAIL n8n_evidence_not_ancestor evidence=$N8N_EVIDENCE_HEAD head=$HEAD_SHA" >&2
  exit 1
}
N8N_RELEVANT=(
  db/domain/UX-025
  scripts/ux025-build-db-bundle.py
  scripts/ux025-db-runtime-apply.sh
  scripts/ux025-generate-financial-api.py
  scripts/ux025-verify-financial-workflow.py
  scripts/ux025-n8n-runtime-apply.sh
  scripts/spc001-generate-financial-api.py
  scripts/spc001-audit-workflow-tenancy.py
  scripts/sec001-transform-class-b.py
  scripts/sec001-build-live-candidates.py
)
if ! git diff --quiet "$N8N_EVIDENCE_HEAD" "$HEAD_SHA" -- "${N8N_RELEVANT[@]}"; then
  echo 'UX025_PREVIEW_APPLY=FAIL n8n_source_changed_since_evidence' >&2
  git diff --name-only "$N8N_EVIDENCE_HEAD" "$HEAD_SHA" -- "${N8N_RELEVANT[@]}" >&2
  exit 1
fi
echo "UX025_N8N_EVIDENCE=PASS evidence_head=$N8N_EVIDENCE_HEAD current_head=$HEAD_SHA"

python3 scripts/ux025-screen-decomposition-source-gate.py
python3 scripts/ux025-category-directory-source-gate.py
python3 scripts/spc001-f4-acceptance-polish-source-gate.py
python3 scripts/spc001-preview-source-gate.py
python3 scripts/spc001-source-gate.py --stage C

(
  cd "$ROOT/miniapp"
  npm ci
  npm run lint
  npm run build
)
[[ -s "$ROOT/miniapp/dist/index.html" ]]
echo 'UX025_FRONTEND_BUILD=PASS'

umask 077
mkdir -p "$OUTPUT_DIR" "$PREVIEW_ROOT"
chmod 700 "$OUTPUT_DIR"
printf '%s\n' "$HEAD_SHA" > "$OUTPUT_DIR/source-head.txt"
printf '%s\n' "$DB_EVIDENCE_HEAD" > "$OUTPUT_DIR/db-evidence-head.txt"
printf '%s\n' "$N8N_EVIDENCE_HEAD" > "$OUTPUT_DIR/n8n-evidence-head.txt"

tar -C "$PREVIEW_ROOT" -czf "$OUTPUT_DIR/preview.before.tgz" .
[[ -s "$OUTPUT_DIR/preview.before.tgz" ]]
echo 'UX025_PREVIEW_BACKUP=PASS'

preview_mutated=0
rollback() {
  local rc=$?
  trap - ERR
  if [[ "$preview_mutated" -eq 1 ]]; then
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    if tar -C "$PREVIEW_ROOT" -xzf "$OUTPUT_DIR/preview.before.tgz"; then
      echo 'UX025_PREVIEW_ROLLBACK=PASS' | tee "$OUTPUT_DIR/rollback.txt" >&2
    else
      echo 'UX025_PREVIEW_ROLLBACK=FAIL' | tee "$OUTPUT_DIR/rollback.txt" >&2
    fi
  fi
  echo "UX025_PREVIEW_APPLY=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}
trap rollback ERR

preview_mutated=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo 'UX025_PREVIEW_RSYNC=PASS'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE_INDEX="$OUTPUT_DIR/remote-index.html"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux025=$STAMP" -o "$REMOTE_INDEX"
[[ -s "$REMOTE_INDEX" ]]
LOCAL_INDEX_SHA="$(sha256sum "$ROOT/miniapp/dist/index.html" | awk '{print $1}')"
REMOTE_INDEX_SHA="$(sha256sum "$REMOTE_INDEX" | awk '{print $1}')"
[[ "$LOCAL_INDEX_SHA" == "$REMOTE_INDEX_SHA" ]]
echo "UX025_PREVIEW_INDEX_IDENTITY=PASS sha256=$LOCAL_INDEX_SHA"

ASSETS="$OUTPUT_DIR/referenced-assets.txt"
grep -oE '/assets/[^\"[:space:]]+\.(js|css)' "$ROOT/miniapp/dist/index.html" | sort -u > "$ASSETS"
[[ -s "$ASSETS" ]]
: > "$OUTPUT_DIR/asset-identity.txt"
while IFS= read -r asset; do
  [[ -n "$asset" ]] || continue
  tmp="$(mktemp)"
  curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$asset?ux025=$STAMP" -o "$tmp"
  lsha="$(sha256sum "$ROOT/miniapp/dist$asset" | awk '{print $1}')"
  rsha="$(sha256sum "$tmp" | awk '{print $1}')"
  rm -f "$tmp"
  [[ "$lsha" == "$rsha" ]]
  echo "UX025_ASSET_IDENTITY=PASS asset=$asset sha256=$lsha" | tee -a "$OUTPUT_DIR/asset-identity.txt"
done < "$ASSETS"
echo 'UX025_PREVIEW_ARTIFACT_IDENTITY=PASS'

{
  echo "HEAD=$HEAD_SHA"
  echo "DB_EVIDENCE_DIR=$DB_EVIDENCE"
  echo "DB_EVIDENCE_HEAD=$DB_EVIDENCE_HEAD"
  echo "N8N_EVIDENCE_DIR=$N8N_EVIDENCE"
  echo "N8N_EVIDENCE_HEAD=$N8N_EVIDENCE_HEAD"
  echo "PREVIEW_INDEX_SHA256=$LOCAL_INDEX_SHA"
  echo 'ACCEPTANCE_SCOPE=SETTINGS_COLLAPSED,CATEGORY_CRUD_HIERARCHY,SCREEN_DECOMPOSITION'
  echo 'DB_MUTATION=ALREADY_APPLIED_FROM_EVIDENCE'
  echo 'N8N_MUTATION=ALREADY_APPLIED_FROM_EVIDENCE'
  echo 'PREVIEW_MUTATION=APPLIED'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'ROLLBACK_TRIGGERED=NO'
  echo 'UX025_PREVIEW_APPLY=PASS'
} > "$OUTPUT_DIR/preview-metadata.txt"

preview_mutated=0
trap - ERR
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

echo "UX025_PREVIEW_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=ALREADY_APPLIED_FROM_EVIDENCE'
echo 'N8N_MUTATION=ALREADY_APPLIED_FROM_EVIDENCE'
echo 'PREVIEW_MUTATION=APPLIED'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'ROLLBACK_TRIGGERED=NO'
echo 'UX025_PREVIEW_APPLY=PASS'
