#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_R3_FRONTEND_BACKUP_DIR:-/var/backups/moneytrack/ux022r3-frontend/$STAMP}"
preview_mutated=0

rollback_on_error() {
  local status=$?
  trap - ERR
  echo "UX022R3_FRONTEND_PREVIEW=FAIL status=$status" >&2
  if (( preview_mutated )); then
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    tar -C "$PREVIEW_ROOT" -xzf "$BACKUP_DIR/preview.before.tgz"
    echo "preview_restore=PASS" >&2
  fi
  exit "$status"
}
trap rollback_on_error ERR

cd "$ROOT"
echo '# Phase'
echo 'UX-022R3 frontend regression recovery'
echo '# Gate'
echo 'frontend_preview_only'
echo "HEAD=$(git rev-parse HEAD)"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi
echo 'clean_checkout=PASS'

bash "$ROOT/scripts/ux022-source-gate.sh"
echo 'source_gate=PASS'

mkdir -p "$BACKUP_DIR" "$PREVIEW_ROOT"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
tar -C "$PREVIEW_ROOT" -czf "$BACKUP_DIR/preview.before.tgz" .
test -s "$BACKUP_DIR/preview.before.tgz"
echo "preview_backup=PASS path=$BACKUP_DIR"

preview_mutated=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo 'preview_rsync=PASS'

local_asset="$(grep -oE '/assets/[^\"[:space:]]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1)"
remote_html="$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux022r3fe=$STAMP")"
remote_asset="$(printf '%s' "$remote_html" | grep -oE '/assets/[^\"[:space:]]+\.js' | head -n1)"
[[ -n "$local_asset" ]]
[[ "$local_asset" == "$remote_asset" ]]

local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
remote_tmp="$(mktemp)"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$remote_asset?ux022r3fe=$STAMP" -o "$remote_tmp"
remote_sha="$(sha256sum "$remote_tmp" | awk '{print $1}')"
rm -f "$remote_tmp"
[[ "$local_sha" == "$remote_sha" ]]

echo "LOCAL_ASSET=$local_asset"
echo "REMOTE_ASSET=$remote_asset"
echo "LOCAL_SHA=$local_sha"
echo "REMOTE_SHA=$remote_sha"
echo 'preview_artifact_identity=PASS'

preview_mutated=0
trap - ERR
echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'UX022R3_FRONTEND_PREVIEW=PASS'
