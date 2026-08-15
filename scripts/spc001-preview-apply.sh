#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
E2_DIR=""
OUTPUT_DIR=""
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --e2-dir) E2_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'SPC001_PREVIEW_DEPLOY=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$E2_DIR" && -n "$OUTPUT_DIR" ]] || {
  echo 'SPC001_PREVIEW_DEPLOY=REFUSED expected_head_e2_output_required' >&2
  exit 2
}
[[ "$E2_DIR" = /* && "$OUTPUT_DIR" = /* && "$PREVIEW_ROOT" = /* ]] || {
  echo 'SPC001_PREVIEW_DEPLOY=REFUSED absolute_paths_required' >&2
  exit 2
}
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'SPC001_PREVIEW_DEPLOY=REFUSED durable_output_required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git npm rsync curl tar sha256sum grep awk find sort mktemp tee python3 xargs; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing command $cmd" >&2; exit 1; }
done

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "ERROR: head mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}
[[ -z "$(git status --porcelain)" ]] || { echo 'ERROR: dirty checkout' >&2; git status --short >&2; exit 1; }

for f in \
  "$E2_DIR/cutover-metadata.txt" \
  "$E2_DIR/post/runtime-verify.txt" \
  "$E2_DIR/post/tenancy-audit.txt" \
  "$E2_DIR/post/live-315.txt" \
  "$E2_DIR/SHA256SUMS"; do
  [[ -s "$f" ]] || { echo "ERROR: E2 evidence missing_or_empty $f" >&2; exit 1; }
done
(
  cd "$E2_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)

for marker in \
  'DB_MUTATION=NONE' \
  'N8N_MUTATION=CUTOVER_APPLIED' \
  'N8N_ROLLBACK=NOT_REQUIRED' \
  'LIVE_315_AFTER_N8N_CUTOVER=PASS' \
  'SPC001_N8N_CUTOVER=PASS'; do
  grep -Fx "$marker" "$E2_DIR/cutover-metadata.txt" >/dev/null
 done
grep -Fx 'SPC001_N8N_CUTOVER_POST_RUNTIME=PASS' "$E2_DIR/post/runtime-verify.txt" >/dev/null
grep -Fx 'SPC001_TENANCY_AUDIT=PASS' "$E2_DIR/post/tenancy-audit.txt" >/dev/null
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$E2_DIR/post/live-315.txt" >/dev/null

E2_HEAD="$(awk -F= '/^HEAD=/{print $2}' "$E2_DIR/cutover-metadata.txt" | tail -n1)"
[[ "$E2_HEAD" =~ ^[0-9a-f]{40}$ ]] || { echo 'ERROR: invalid E2 HEAD evidence' >&2; exit 1; }
git merge-base --is-ancestor "$E2_HEAD" "$HEAD_SHA" || {
  echo "ERROR: accepted E2 head is not ancestor e2=$E2_HEAD current=$HEAD_SHA" >&2
  exit 1
}

# E2 stays accepted only if every post-E2 source change is preview-control-only.
mapfile -t POST_E2_CHANGED < <(git diff --name-only "$E2_HEAD..$HEAD_SHA")
for path in "${POST_E2_CHANGED[@]}"; do
  case "$path" in
    scripts/spc001-preview-apply.sh|scripts/spc001-preview-source-gate.py|.github/workflows/spc001-source-contract.yml) ;;
    *) echo "ERROR: runtime-relevant source changed after accepted E2: $path" >&2; exit 1 ;;
  esac
done
echo "E2_TO_PREVIEW_CONTROL_DELTA=PASS files=${#POST_E2_CHANGED[@]}"
echo 'E2_ACCEPTANCE_EVIDENCE=PASS'

python3 "$ROOT/scripts/spc001-preview-source-gate.py"
python3 "$ROOT/scripts/spc001-source-gate.py" --stage C
python3 "$ROOT/scripts/spc001-cumulative-source-gate.py"

echo '=== FRONTEND INSTALL / LINT / BUILD ==='
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
printf '%s\n' "$E2_HEAD" > "$OUTPUT_DIR/e2-head.txt"
sha256sum "$E2_DIR/SHA256SUMS" > "$OUTPUT_DIR/e2-manifest.sha256"

tar -C "$PREVIEW_ROOT" -czf "$OUTPUT_DIR/preview.before.tgz" .
[[ -s "$OUTPUT_DIR/preview.before.tgz" ]]
echo "PREVIEW_BACKUP=PASS path=$OUTPUT_DIR/preview.before.tgz"

find "$ROOT/miniapp/dist" -type f -print0 | sort -z | xargs -0 sha256sum > "$OUTPUT_DIR/local-dist.sha256"
[[ -s "$OUTPUT_DIR/local-dist.sha256" ]]

preview_mutated=0
rollback_on_error() {
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
  echo "SPC001_PREVIEW_DEPLOY=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}
trap rollback_on_error ERR

preview_mutated=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo 'PREVIEW_RSYNC=PASS'

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE_INDEX="$OUTPUT_DIR/remote-index.html"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?spc001f=$STAMP" -o "$REMOTE_INDEX"
[[ -s "$REMOTE_INDEX" ]]

LOCAL_INDEX_SHA="$(sha256sum "$ROOT/miniapp/dist/index.html" | awk '{print $1}')"
REMOTE_INDEX_SHA="$(sha256sum "$REMOTE_INDEX" | awk '{print $1}')"
[[ "$LOCAL_INDEX_SHA" == "$REMOTE_INDEX_SHA" ]]
echo "PREVIEW_INDEX_IDENTITY=PASS sha256=$LOCAL_INDEX_SHA"

ASSET_LIST="$OUTPUT_DIR/referenced-assets.txt"
grep -oE '/assets/[^\"[:space:]]+\.(js|css)' "$ROOT/miniapp/dist/index.html" | sort -u > "$ASSET_LIST"
[[ -s "$ASSET_LIST" ]]
: > "$OUTPUT_DIR/asset-identity.txt"
while IFS= read -r asset; do
  [[ -n "$asset" ]] || continue
  local_file="$ROOT/miniapp/dist$asset"
  [[ -s "$local_file" ]]
  remote_file="$(mktemp)"
  curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$asset?spc001f=$STAMP" -o "$remote_file"
  local_sha="$(sha256sum "$local_file" | awk '{print $1}')"
  remote_sha="$(sha256sum "$remote_file" | awk '{print $1}')"
  rm -f "$remote_file"
  [[ "$local_sha" == "$remote_sha" ]]
  printf 'ASSET_IDENTITY=PASS asset=%s sha256=%s\n' "$asset" "$local_sha" | tee -a "$OUTPUT_DIR/asset-identity.txt"
done < "$ASSET_LIST"

grep -Fq 'ASSET_IDENTITY=PASS' "$OUTPUT_DIR/asset-identity.txt"
echo 'PREVIEW_ARTIFACT_IDENTITY=PASS'

{
  echo "HEAD=$HEAD_SHA"
  echo "E2_HEAD=$E2_HEAD"
  echo "E2_EVIDENCE_DIR=$E2_DIR"
  echo "PREVIEW_URL=$PREVIEW_URL"
  echo "PREVIEW_ROOT=$PREVIEW_ROOT"
  echo "PREVIEW_INDEX_SHA256=$LOCAL_INDEX_SHA"
  echo 'DB_MUTATION=NONE'
  echo 'N8N_MUTATION=NONE'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'PREVIEW_MUTATION=APPLIED'
  echo 'SPC001_PREVIEW_DEPLOY=PASS'
} > "$OUTPUT_DIR/preview-metadata.txt"

preview_mutated=0
trap - ERR

python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import hashlib,sys
root=Path(sys.argv[1]); manifest=root/'SHA256SUMS'
lines=[]
for p in sorted(root.rglob('*')):
    if p.is_file() and p != manifest:
        h=hashlib.sha256(p.read_bytes()).hexdigest()
        lines.append(f'{h}  {p.relative_to(root)}\n')
manifest.write_text(''.join(lines),encoding='utf-8')
PY
sync

echo "SPC001_PREVIEW_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'PREVIEW_MUTATION=APPLIED'
echo 'SPC001_PREVIEW_DEPLOY=PASS'
