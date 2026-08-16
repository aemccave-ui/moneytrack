#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
F2R1_DIR=""
OUTPUT_DIR=""
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --f2r1-dir) F2R1_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_SHARED_PREVIEW=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$F2R1_DIR" && -n "$OUTPUT_DIR" ]] || exit 2
[[ "$F2R1_DIR" = /* && "$OUTPUT_DIR" = /* && "$PREVIEW_ROOT" = /* ]] || exit 2
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'SPC001_SHARED_PREVIEW=REFUSED durable_output_required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git npm rsync curl tar sha256sum grep awk sort mktemp tee python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing command $cmd" >&2; exit 1; }
done

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "ERROR: head mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || { echo 'ERROR: dirty checkout' >&2; git status --short >&2; exit 1; }

for f in "$F2R1_DIR/preview-metadata.txt" "$F2R1_DIR/source-head.txt" "$F2R1_DIR/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "ERROR: F2R1 evidence missing $f" >&2; exit 1; }
done
(
  cd "$F2R1_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
grep -Fx 'SPC001_F2R1_PREVIEW=PASS' "$F2R1_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'DB_MUTATION=NONE' "$F2R1_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'N8N_MUTATION=NONE' "$F2R1_DIR/preview-metadata.txt" >/dev/null
grep -Fx 'PRODUCTION_FRONTEND_MUTATION=NONE' "$F2R1_DIR/preview-metadata.txt" >/dev/null

F2R1_HEAD="$(cat "$F2R1_DIR/source-head.txt")"
[[ "$F2R1_HEAD" =~ ^[0-9a-f]{40}$ ]]
git merge-base --is-ancestor "$F2R1_HEAD" "$HEAD_SHA"

mapfile -t CHANGED < <(git diff --name-only "$F2R1_HEAD..$HEAD_SHA")
for path in "${CHANGED[@]}"; do
  case "$path" in
    miniapp/src/SpaceGate.jsx|miniapp/src/spc001-space.css|scripts/spc001-shared-preview-apply.sh|scripts/spc001-preview-source-gate.py) ;;
    *) echo "ERROR: non-shared-UI source changed after accepted F2R1: $path" >&2; exit 1 ;;
  esac
done
echo "F2R1_TO_SHARED_UI_SAFE_DELTA=PASS files=${#CHANGED[@]}"
echo 'F2R1_ACCEPTANCE_EVIDENCE=PASS'

python3 "$ROOT/scripts/spc001-preview-source-gate.py"
python3 "$ROOT/scripts/spc001-source-gate.py" --stage C

(
  cd "$ROOT/miniapp"
  npm ci
  npm run lint
  npm run build
)
[[ -s "$ROOT/miniapp/dist/index.html" ]]
echo 'FRONTEND_BUILD=PASS'

umask 077
mkdir -p "$OUTPUT_DIR" "$PREVIEW_ROOT"
chmod 700 "$OUTPUT_DIR"
printf '%s\n' "$HEAD_SHA" > "$OUTPUT_DIR/source-head.txt"
printf '%s\n' "$F2R1_HEAD" > "$OUTPUT_DIR/f2r1-head.txt"
sha256sum "$F2R1_DIR/SHA256SUMS" > "$OUTPUT_DIR/f2r1-manifest.sha256"

tar -C "$PREVIEW_ROOT" -czf "$OUTPUT_DIR/preview.before.tgz" .
[[ -s "$OUTPUT_DIR/preview.before.tgz" ]]
echo 'PREVIEW_BACKUP=PASS'

preview_mutated=0
rollback() {
  local rc=$?
  trap - ERR
  if [[ "$preview_mutated" -eq 1 ]]; then
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    if tar -C "$PREVIEW_ROOT" -xzf "$OUTPUT_DIR/preview.before.tgz"; then
      echo 'PREVIEW_ROLLBACK=PASS' | tee "$OUTPUT_DIR/rollback.txt" >&2
    else
      echo 'PREVIEW_ROLLBACK=FAIL' | tee "$OUTPUT_DIR/rollback.txt" >&2
    fi
  fi
  echo "SPC001_SHARED_PREVIEW=FAIL rc=$rc" >&2
  exit "$rc"
}
trap rollback ERR

preview_mutated=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo 'PREVIEW_RSYNC=PASS'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE_INDEX="$OUTPUT_DIR/remote-index.html"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?spc001shared=$STAMP" -o "$REMOTE_INDEX"
[[ -s "$REMOTE_INDEX" ]]
LOCAL_INDEX_SHA="$(sha256sum "$ROOT/miniapp/dist/index.html" | awk '{print $1}')"
REMOTE_INDEX_SHA="$(sha256sum "$REMOTE_INDEX" | awk '{print $1}')"
[[ "$LOCAL_INDEX_SHA" == "$REMOTE_INDEX_SHA" ]]
echo "PREVIEW_INDEX_IDENTITY=PASS sha256=$LOCAL_INDEX_SHA"

ASSETS="$OUTPUT_DIR/referenced-assets.txt"
grep -oE '/assets/[^\"[:space:]]+\.(js|css)' "$ROOT/miniapp/dist/index.html" | sort -u > "$ASSETS"
[[ -s "$ASSETS" ]]
: > "$OUTPUT_DIR/asset-identity.txt"
while IFS= read -r asset; do
  [[ -n "$asset" ]] || continue
  tmp="$(mktemp)"
  curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$asset?spc001shared=$STAMP" -o "$tmp"
  lsha="$(sha256sum "$ROOT/miniapp/dist$asset" | awk '{print $1}')"
  rsha="$(sha256sum "$tmp" | awk '{print $1}')"
  rm -f "$tmp"
  [[ "$lsha" == "$rsha" ]]
  echo "ASSET_IDENTITY=PASS asset=$asset sha256=$lsha" | tee -a "$OUTPUT_DIR/asset-identity.txt"
done < "$ASSETS"
echo 'PREVIEW_ARTIFACT_IDENTITY=PASS'

{
  echo "HEAD=$HEAD_SHA"
  echo "F2R1_HEAD=$F2R1_HEAD"
  echo "F2R1_EVIDENCE_DIR=$F2R1_DIR"
  echo "PREVIEW_INDEX_SHA256=$LOCAL_INDEX_SHA"
  echo 'DB_MUTATION=NONE'
  echo 'N8N_MUTATION=NONE'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'PREVIEW_MUTATION=APPLIED'
  echo 'SPC001_SHARED_PREVIEW=PASS'
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

echo "SPC001_SHARED_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'SPC001_SHARED_PREVIEW=PASS'
