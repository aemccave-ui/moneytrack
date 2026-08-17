#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APPLY=0
EXPECTED_HEAD=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; exit 2 ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || { echo 'UX025_DB_APPLY=REFUSED explicit_--apply_required' >&2; exit 2; }
[[ -n "$EXPECTED_HEAD" && -n "$OUTPUT_DIR" ]] || { echo 'UX025_DB_APPLY=REFUSED expected_head_output_required' >&2; exit 2; }
[[ "$OUTPUT_DIR" = /* ]] || { echo 'ERROR: --output-dir must be absolute' >&2; exit 2; }
case "$OUTPUT_DIR" in /tmp|/tmp/*) echo 'UX025_DB_APPLY=REFUSED durable_output_required' >&2; exit 2;; esac
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output exists: $OUTPUT_DIR" >&2; exit 2; }

for cmd in git docker python3 sha256sum find grep awk cp sync; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "UX025_DB_APPLY=FAIL missing_command=$cmd" >&2; exit 1; }
done

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || { echo "UX025_DB_APPLY=FAIL head_mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'UX025_DB_APPLY=FAIL dirty_checkout' >&2; git status --short >&2; exit 1; }

python3 scripts/ux025-screen-decomposition-source-gate.py
python3 scripts/ux025-category-directory-source-gate.py

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init
[[ "$UX022_DB_MODE" == container ]] || { echo "UX025_DB_APPLY=FAIL unsupported_db_mode=$UX022_DB_MODE" >&2; exit 1; }
for c in "$UX022_DB_CONTAINER" n8n postgres; do
  docker inspect "$c" >/dev/null 2>&1 || { echo "UX025_DB_APPLY=FAIL container_missing=$c" >&2; exit 1; }
  [[ "$(docker inspect "$c" --format '{{.State.Running}}')" == true ]] || { echo "UX025_DB_APPLY=FAIL container_not_running=$c" >&2; exit 1; }
done

umask 077
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

COMMIT_BUNDLE="$OUTPUT_DIR/ux025-category-directory.sql"
ROLLBACK_SQL="$ROOT/db/domain/UX-025/099_rollback_category_directory.sql"
CLONE_APPLY_LOG="$OUTPUT_DIR/clone-apply.log"
CLONE_VERIFY_LOG="$OUTPUT_DIR/clone-verify.log"
CLONE_REHEARSAL_LOG="$OUTPUT_DIR/clone-crud-rehearsal.log"
CLONE_ROLLBACK_LOG="$OUTPUT_DIR/clone-schema-rollback.log"
CLONE_REAPPLY_LOG="$OUTPUT_DIR/clone-reapply.log"
LIVE_APPLY_LOG="$OUTPUT_DIR/live-apply.log"
LIVE_VERIFY_LOG="$OUTPUT_DIR/live-post-verify.log"
BACKUP_LOG="$OUTPUT_DIR/prod-h2-backup.log"
METADATA="$OUTPUT_DIR/db-metadata.txt"

python3 scripts/ux025-build-db-bundle.py --output "$COMMIT_BUNDLE" --final commit
BUNDLE_SHA="$(sha256sum "$COMMIT_BUNDLE" | awk '{print $1}')"
ROLLBACK_SHA="$(sha256sum "$ROLLBACK_SQL" | awk '{print $1}')"
echo "UX025_DB_BUNDLE_SHA256=$BUNDLE_SHA"
echo "UX025_DB_ROLLBACK_SHA256=$ROLLBACK_SHA"

# Fresh complete recovery point before any live schema mutation.
BACKUP_ROOT="$OUTPUT_DIR/prod-h2" bash "$ROOT/scripts/prod-h2-backup-now.sh" >"$BACKUP_LOG" 2>&1
mapfile -t BACKUP_DIRS < <(find "$OUTPUT_DIR/prod-h2" -mindepth 1 -maxdepth 1 -type d | sort)
[[ "${#BACKUP_DIRS[@]}" -eq 1 ]] || { echo 'UX025_DB_APPLY=FAIL backup_directory_count' >&2; exit 1; }
BACKUP_DIR="${BACKUP_DIRS[0]}"
for f in COMPLETE SHA256SUMS moneytrack.dump; do
  [[ -s "$BACKUP_DIR/$f" ]] || { echo "UX025_DB_APPLY=FAIL backup_file_missing=$f" >&2; exit 1; }
done
(cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS >/dev/null)
echo "UX025_FRESH_BACKUP=PASS path=$BACKUP_DIR"

CLONE_DB="ux025_${HEAD_SHA:0:8}_$$_${RANDOM}"
CLONE_CREATED=0
LIVE_MUTATED=0

clone_psql() {
  local file="$1"
  docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec psql -X -h 127.0.0.1 -U "$POSTGRES_USER" -d "$1" -v ON_ERROR_STOP=1
  ' sh "$CLONE_DB" < "$file"
}

drop_clone() {
  if [[ "$CLONE_CREATED" -eq 1 ]]; then
    docker exec "$UX022_DB_CONTAINER" sh -ceu '
      export PGPASSWORD="$POSTGRES_PASSWORD"
      exec dropdb -h 127.0.0.1 -U "$POSTGRES_USER" --if-exists "$1"
    ' sh "$CLONE_DB" >/dev/null 2>&1 || true
    CLONE_CREATED=0
  fi
}

rollback_on_error() {
  local rc=$?
  trap - ERR
  drop_clone
  if [[ "$LIVE_MUTATED" -eq 1 ]]; then
    echo 'UX025_DB_ROLLBACK_TRIGGERED=YES' >&2
    if ux022_db_psql_file "$ROLLBACK_SQL" >"$OUTPUT_DIR/live-schema-rollback.log" 2>&1; then
      echo 'UX025_DB_SCHEMA_ROLLBACK=PASS' >&2
    else
      echo 'UX025_DB_SCHEMA_ROLLBACK=FAIL' >&2
    fi
  fi
  echo "UX025_DB_APPLY=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  exit "$rc"
}
trap rollback_on_error ERR
trap drop_clone EXIT

# Restore a real backup clone and prove apply -> CRUD/isolation -> inverse
# rollback -> reapply before touching live MoneyTrack.
docker exec "$UX022_DB_CONTAINER" sh -ceu '
  export PGPASSWORD="$POSTGRES_PASSWORD"
  exec createdb -h 127.0.0.1 -U "$POSTGRES_USER" --template=template0 "$1"
' sh "$CLONE_DB"
CLONE_CREATED=1

docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
  export PGPASSWORD="$POSTGRES_PASSWORD"
  exec pg_restore -h 127.0.0.1 -U "$POSTGRES_USER" -d "$1" --exit-on-error --single-transaction
' sh "$CLONE_DB" < "$BACKUP_DIR/moneytrack.dump"
echo 'UX025_CLONE_RESTORE=PASS'

clone_psql "$COMMIT_BUNDLE" >"$CLONE_APPLY_LOG" 2>&1
clone_psql "$ROOT/db/domain/UX-025/090_verify_category_directory.sql" >"$CLONE_VERIFY_LOG" 2>&1
grep -F 'UX025_DB_POST_VERIFY_READONLY=PASS' "$CLONE_VERIFY_LOG" >/dev/null
clone_psql "$ROOT/db/domain/UX-025/091_rehearse_category_crud.sql" >"$CLONE_REHEARSAL_LOG" 2>&1
grep -F 'UX025_CATEGORY_CRUD_REHEARSAL=PASS' "$CLONE_REHEARSAL_LOG" >/dev/null
grep -F 'UX025_REHEARSAL_TERMINAL_ROLLBACK=PASS' "$CLONE_REHEARSAL_LOG" >/dev/null

echo 'UX025_CLONE_CRUD_REHEARSAL=PASS'

clone_psql "$ROLLBACK_SQL" >"$CLONE_ROLLBACK_LOG" 2>&1
# Inverse rollback must remove UX-025 dispatcher and CRUD functions.
docker exec "$UX022_DB_CONTAINER" sh -ceu '
  export PGPASSWORD="$POSTGRES_PASSWORD"
  test "$(psql -X -h 127.0.0.1 -U "$POSTGRES_USER" -d "$1" -Atc "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='\''moneytrack'\'' and p.proname in ('\''category_directory_space_v1'\'','\''category_create_space_v1'\'','\''category_edit_space_v1'\'','\''category_delete_space_v1'\'','\''ux025_financial_api_dispatch_v1'\'');")" = 0
' sh "$CLONE_DB"
echo 'UX025_CLONE_SCHEMA_ROLLBACK=PASS'

clone_psql "$COMMIT_BUNDLE" >"$CLONE_REAPPLY_LOG" 2>&1
clone_psql "$ROOT/db/domain/UX-025/090_verify_category_directory.sql" >>"$CLONE_REAPPLY_LOG" 2>&1
grep -F 'UX025_DB_POST_VERIFY_READONLY=PASS' "$CLONE_REAPPLY_LOG" >/dev/null
echo 'UX025_CLONE_REAPPLY=PASS'
drop_clone

# Fail closed on unexpected partial prior deployment.
PREEXISTING="$(ux022_db_query_scalar "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='moneytrack' and p.proname='ux025_financial_api_dispatch_v1';")"
[[ "$PREEXISTING" == 0 ]] || { echo "UX025_DB_APPLY=FAIL preexisting_ux025_dispatch=$PREEXISTING" >&2; exit 1; }

LIVE_MUTATED=1
ux022_db_psql_file "$COMMIT_BUNDLE" >"$LIVE_APPLY_LOG" 2>&1
ux022_db_psql_file "$ROOT/db/domain/UX-025/090_verify_category_directory.sql" >"$LIVE_VERIFY_LOG" 2>&1
grep -F 'UX025_DB_POST_VERIFY_READONLY=PASS' "$LIVE_VERIFY_LOG" >/dev/null
LIVE_MUTATED=0
trap - ERR

echo 'UX025_LIVE_DB_APPLY=PASS'
echo 'UX025_LIVE_DB_POST_VERIFY=PASS'

{
  echo "HEAD=$HEAD_SHA"
  echo "DB_BUNDLE_SHA256=$BUNDLE_SHA"
  echo "ROLLBACK_SQL_SHA256=$ROLLBACK_SHA"
  echo "BACKUP_DIR=$BACKUP_DIR"
  echo 'CLONE_RESTORE=PASS'
  echo 'CLONE_CRUD_REHEARSAL=PASS'
  echo 'CLONE_SCHEMA_ROLLBACK=PASS'
  echo 'CLONE_REAPPLY=PASS'
  echo 'LIVE_DB_MUTATION=APPLIED'
  echo 'LIVE_DB_POST_VERIFY=PASS'
  echo 'N8N_MUTATION=NONE'
  echo 'PREVIEW_MUTATION=NONE'
  echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
  echo 'UX025_DB_APPLY=PASS'
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

echo "UX025_DB_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'UX025_DB_APPLY=PASS'
