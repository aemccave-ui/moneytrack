#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_R3_BACKUP_DIR:-/var/backups/moneytrack/ux022r3/$STAMP}"

# shellcheck source=/dev/null
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

mkdir -p "$BACKUP_DIR" "$PREVIEW_ROOT"

db_applied=0
preview_mutated=0
apply_sql="$(mktemp)"
verify_sql="$(mktemp)"

cleanup() {
  rm -f "$apply_sql" "$verify_sql"
}

rollback_on_error() {
  local status=$?
  trap - ERR
  echo "UX022R3_APPLY_PREVIEW=FAIL status=$status" >&2

  if (( preview_mutated )); then
    echo "preview_restore=START backup=$BACKUP_DIR/preview.before.tgz" >&2
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    if tar -C "$PREVIEW_ROOT" -xzf "$BACKUP_DIR/preview.before.tgz"; then
      echo "preview_restore=PASS" >&2
    else
      echo "preview_restore=FAIL" >&2
    fi
  fi

  if (( db_applied )); then
    echo "r3_db_rollback=START" >&2
    if ux022_db_psql_file "$ROOT/db/domain/UX-022/045_grouping_account_rollback.sql"; then
      echo "r3_db_rollback=PASS" >&2
    else
      echo "r3_db_rollback=FAIL manual_backup=$BACKUP_DIR/moneytrack.before.dump" >&2
    fi
  fi

  exit "$status"
}

trap cleanup EXIT
trap rollback_on_error ERR

cd "$ROOT"

echo "# Phase"
echo "UX-022R3 persistent DB apply + preview frontend"
echo "# Gate"
echo "preflight"
echo "HEAD=$(git rev-parse HEAD)"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "clean_checkout=FAIL" >&2
  git status --short >&2
  exit 1
fi
echo "clean_checkout=PASS"

# Re-run both already-approved non-mutating gates immediately before mutation.
bash "$ROOT/scripts/ux022-source-gate.sh"
bash "$ROOT/scripts/ux022-migration-gate.sh"
echo "preflight=PASS"

# Full schema+data backup and preview snapshot before any persistent change.
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
ux022_db_pg_dump_schema moneytrack "$BACKUP_DIR/moneytrack.before.dump"
test -s "$BACKUP_DIR/moneytrack.before.dump"
tar -C "$PREVIEW_ROOT" -czf "$BACKUP_DIR/preview.before.tgz" .
test -s "$BACKUP_DIR/preview.before.tgz"
echo "backup=PASS path=$BACKUP_DIR"

# Persistent apply uses exactly the same rendered migration body as the dry-run gate.
{
  echo 'begin;'
  bash "$ROOT/scripts/ux022-render-migration.sh"
  echo 'commit;'
} > "$apply_sql"

ux022_db_psql_file "$apply_sql"
db_applied=1
echo "db_apply=PASS"

# Verify the committed runtime state before exposing the new frontend.
cat \
  "$ROOT/db/domain/UX-022/905_reference_inventory.sql" \
  "$ROOT/db/domain/UX-022/910_verify_grouping_invariant.sql" \
  > "$verify_sql"
ux022_db_psql_file "$verify_sql"
echo "db_post_verify=PASS"

# Frontend preview only. No n8n mutation and no production frontend target exists here.
preview_mutated=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo "preview_rsync=PASS"

local_asset="$(grep -oE '/assets/[^\"[:space:]]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1)"
remote_html="$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux022r3=$STAMP")"
remote_asset="$(printf '%s' "$remote_html" | grep -oE '/assets/[^\"[:space:]]+\.js' | head -n1)"

[[ -n "$local_asset" ]]
[[ "$local_asset" == "$remote_asset" ]]

local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
remote_tmp="$(mktemp)"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$remote_asset?ux022r3=$STAMP" -o "$remote_tmp"
remote_sha="$(sha256sum "$remote_tmp" | awk '{print $1}')"
rm -f "$remote_tmp"

[[ "$local_sha" == "$remote_sha" ]]

echo "LOCAL_ASSET=$local_asset"
echo "REMOTE_ASSET=$remote_asset"
echo "LOCAL_SHA=$local_sha"
echo "REMOTE_SHA=$remote_sha"
echo "preview_artifact_identity=PASS"

# Successful paired deployment; do not trigger rollback trap from here onward.
preview_mutated=0
trap - ERR

echo "rollback_point=$BACKUP_DIR"
echo "UX022R3_APPLY_PREVIEW=PASS"
