#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR="/tmp/moneytrack-spc001-db-rollback-rehearsal"
if [[ "${1:-}" == "--output-dir" ]]; then
  [[ -n "${2:-}" ]] || { echo 'ERROR: --output-dir requires a value' >&2; exit 2; }
  OUTPUT_DIR="$2"
  shift 2
fi
[[ $# -eq 0 ]] || { echo "ERROR: unexpected arguments: $*" >&2; exit 2; }

for command_name in python3 sha256sum git docker cmp grep; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "SPC001_DB_ROLLBACK_REHEARSAL=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL dirty_checkout' >&2
  git status --short >&2
  exit 1
fi

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

# This gate deliberately supports only the runtime topology proven by the live
# forensic: the canonical PostgreSQL container. Executing the rollback bundle
# against the live DB is forbidden because PostgreSQL sequence nextval/setval
# effects are not transactionally rolled back. The rehearsal therefore restores
# an exact live backup into a disposable database in the same PostgreSQL server.
if [[ "$UX022_DB_MODE" != "container" ]]; then
  echo "SPC001_DB_ROLLBACK_REHEARSAL=FAIL unsupported_db_runtime_mode=$UX022_DB_MODE" >&2
  exit 1
fi

docker exec "$UX022_DB_CONTAINER" sh -ceu '
  command -v psql >/dev/null
  command -v pg_dump >/dev/null
  command -v pg_restore >/dev/null
  command -v createdb >/dev/null
  command -v dropdb >/dev/null
  : "${POSTGRES_USER:?POSTGRES_USER required}"
  : "${POSTGRES_DB:?POSTGRES_DB required}"
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"
' >/dev/null

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

ROLLBACK_BUNDLE="$OUTPUT_DIR/spc001-migration-rollback.sql"
BACKUP="$OUTPUT_DIR/live-pre-rehearsal.dump"
BACKUP_LIST="$OUTPUT_DIR/live-pre-rehearsal.list"
LIVE_FP_BEFORE="$OUTPUT_DIR/live-table-fingerprint-before.txt"
LIVE_FP_AFTER="$OUTPUT_DIR/live-table-fingerprint-after.txt"
CLONE_FP_BEFORE="$OUTPUT_DIR/clone-table-fingerprint-before.txt"
CLONE_FP_AFTER="$OUTPUT_DIR/clone-table-fingerprint-after.txt"
CLONE_SCHEMA_BEFORE_RAW="$OUTPUT_DIR/clone-schema-before.raw.sql"
CLONE_SCHEMA_AFTER_RAW="$OUTPUT_DIR/clone-schema-after.raw.sql"
CLONE_SCHEMA_BEFORE="$OUTPUT_DIR/clone-schema-before.sql"
CLONE_SCHEMA_AFTER="$OUTPUT_DIR/clone-schema-after.sql"
CLONE_PREFLIGHT="$OUTPUT_DIR/clone-strict-preflight-before.txt"
CLONE_REPAIRABILITY_BEFORE="$OUTPUT_DIR/clone-repairability-before.txt"
CLONE_REPAIRABILITY_AFTER="$OUTPUT_DIR/clone-repairability-after.txt"
CLONE_PREFLIGHT_AFTER="$OUTPUT_DIR/clone-strict-preflight-after.txt"
REHEARSAL_REPORT="$OUTPUT_DIR/rollback-rehearsal.txt"
METADATA="$OUTPUT_DIR/rehearsal-metadata.txt"
MANIFEST="$OUTPUT_DIR/SHA256SUMS"

HEAD_SHA="$(git rev-parse HEAD)"
CLONE_DB="spc001_rehearsal_${HEAD_SHA:0:8}_$$_${RANDOM}"
CLONE_CREATED=0

spc001_drop_clone() {
  if [[ "$CLONE_CREATED" -eq 1 ]]; then
    docker exec "$UX022_DB_CONTAINER" sh -ceu '
      export PGPASSWORD="$POSTGRES_PASSWORD"
      exec dropdb -h 127.0.0.1 -U "$POSTGRES_USER" --if-exists "$1"
    ' sh "$CLONE_DB" >/dev/null 2>&1 || true
    CLONE_CREATED=0
  fi
}
trap spc001_drop_clone EXIT

spc001_live_backup() {
  docker exec "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec pg_dump \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      --format=custom
  ' > "$BACKUP"
}

spc001_archive_list() {
  docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
    exec pg_restore --list
  ' < "$BACKUP" > "$BACKUP_LIST"
}

spc001_clone_create() {
  docker exec "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec createdb \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      --template=template0 \
      "$1"
  ' sh "$CLONE_DB"
  CLONE_CREATED=1
}

spc001_clone_restore() {
  docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec pg_restore \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      -d "$1" \
      --exit-on-error \
      --single-transaction
  ' sh "$CLONE_DB" < "$BACKUP"
}

spc001_clone_psql_file() {
  local file="$1"
  docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec psql -X \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      -d "$1" \
      -v ON_ERROR_STOP=1
  ' sh "$CLONE_DB" < "$file"
}

spc001_clone_schema_dump() {
  local output="$1"
  docker exec "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec pg_dump \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      -d "$1" \
      --schema-only \
      --format=plain \
      --no-owner \
      --no-privileges
  ' sh "$CLONE_DB" > "$output"
}

spc001_normalize_schema_dump() {
  local input="$1"
  local output="$2"
  python3 - "$input" "$output" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
lines=[]
for line in src.splitlines():
    # PostgreSQL 17+ adds a random psql restrict key to plain dumps. It is not
    # database state and must not make before/after schema comparison unstable.
    if line.startswith('\\restrict ') or line.startswith('\\unrestrict '):
        continue
    lines.append(line)
Path(sys.argv[2]).write_text('\n'.join(lines)+'\n',encoding='utf-8')
PY
}

spc001_fingerprint_live() {
  local output="$1"
  ux022_db_psql_file "$ROOT/db/domain/SPC-001/313_runtime_table_fingerprint.sql" \
    2>&1 | grep -E '^(SPC001_TABLE_FINGERPRINT=|TABLE_FINGERPRINT\|)' > "$output"
  grep -Fx 'SPC001_TABLE_FINGERPRINT=BEGIN' "$output" >/dev/null
  grep -Fx 'SPC001_TABLE_FINGERPRINT=END' "$output" >/dev/null
}

spc001_fingerprint_clone() {
  local output="$1"
  spc001_clone_psql_file "$ROOT/db/domain/SPC-001/313_runtime_table_fingerprint.sql" \
    2>&1 | grep -E '^(SPC001_TABLE_FINGERPRINT=|TABLE_FINGERPRINT\|)' > "$output"
  grep -Fx 'SPC001_TABLE_FINGERPRINT=BEGIN' "$output" >/dev/null
  grep -Fx 'SPC001_TABLE_FINGERPRINT=END' "$output" >/dev/null
}

echo '=== SPC-001D ISOLATED ROLLBACK REHEARSAL ==='
echo "HEAD=$HEAD_SHA"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'LIVE_DB_POLICY=READ_ONLY'
echo 'REHEARSAL_TARGET=DISPOSABLE_DATABASE_CLONE'
echo 'COMMIT_FORBIDDEN=YES'

echo
echo '=== SOURCE / BUNDLE ==='
python3 "$ROOT/scripts/spc001-migration-source-gate.py"
python3 "$ROOT/scripts/spc001-build-db-migration.py" \
  --output "$ROLLBACK_BUNDLE" \
  --final rollback

python3 - "$ROLLBACK_BUNDLE" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text(encoding='utf-8')
tx=[line.strip().lower() for line in text.splitlines()
    if re.fullmatch(r'\s*(?:begin|commit|rollback)\s*;\s*',line,re.I)]
assert tx==['begin;','rollback;'],tx
assert 'CONTROLLED LEGACY REFERENCE REPAIR' in text
assert 'SPC001_REFERENCE_REPAIR_LEDGER=PASS' in text
assert 'CONTROLLED FILTER PRESET REFERENCE REPAIR' in text
assert 'SPC001_FILTER_PRESET_REFERENCE_REPAIR=PASS' in text
assert 'SPC001_FILTER_PRESET_REFERENCE_LEDGER=PASS' in text
assert 'SPC001_FILTER_PRESET_REFERENCES=PASS' in text
print('rollback_bundle_exact_shape=PASS')
PY

echo
echo '=== LIVE PRE-REHEARSAL READ-ONLY CHECK ==='
ux022_db_psql_file "$ROOT/db/domain/SPC-001/308_migration_reference_repairability_preflight.sql" \
  > "$OUTPUT_DIR/live-repairability.txt" 2>&1
grep -Fx 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS' "$OUTPUT_DIR/live-repairability.txt" >/dev/null
spc001_fingerprint_live "$LIVE_FP_BEFORE"
echo 'live_repairability=PASS'
echo 'live_table_fingerprint_before=PASS'

echo
echo '=== LIVE FULL DATABASE BACKUP ==='
spc001_live_backup
test -s "$BACKUP"
spc001_archive_list
test -s "$BACKUP_LIST"
BACKUP_SHA="$(sha256sum "$BACKUP" | awk '{print $1}')"
echo "backup_sha256=$BACKUP_SHA"
echo 'backup_archive_list=PASS'

echo
echo '=== RESTORE DISPOSABLE CLONE ==='
spc001_clone_create
spc001_clone_restore
spc001_fingerprint_clone "$CLONE_FP_BEFORE"
spc001_clone_schema_dump "$CLONE_SCHEMA_BEFORE_RAW"
spc001_normalize_schema_dump "$CLONE_SCHEMA_BEFORE_RAW" "$CLONE_SCHEMA_BEFORE"
echo "clone_database=$CLONE_DB"
echo 'clone_restore=PASS'

echo
echo '=== CLONE BASELINE CONTRACT ==='
spc001_clone_psql_file "$ROOT/db/domain/SPC-001/308_migration_reference_repairability_preflight.sql" \
  > "$CLONE_REPAIRABILITY_BEFORE" 2>&1
grep -Fx 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS' "$CLONE_REPAIRABILITY_BEFORE" >/dev/null

set +e
spc001_clone_psql_file "$ROOT/db/domain/SPC-001/305_migration_preflight.sql" \
  > "$CLONE_PREFLIGHT" 2>&1
CLONE_STRICT_BEFORE_RC=$?
set -e
if [[ "$CLONE_STRICT_BEFORE_RC" -eq 0 ]]; then
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL clone_strict_preflight_unexpected_pass' >&2
  exit 1
fi
grep -F 'SPC001_DB_PREFLIGHT_FAILED:' "$CLONE_PREFLIGHT" >/dev/null
echo 'clone_baseline_contract=PASS'

echo
echo '=== EXECUTE ATOMIC ROLLBACK BUNDLE ON CLONE ==='
set +e
spc001_clone_psql_file "$ROLLBACK_BUNDLE" > "$REHEARSAL_REPORT" 2>&1
REHEARSAL_RC=$?
set -e
if [[ "$REHEARSAL_RC" -ne 0 ]]; then
  echo "SPC001_DB_ROLLBACK_REHEARSAL=FAIL migration_rc=$REHEARSAL_RC" >&2
  tail -n 120 "$REHEARSAL_REPORT" >&2 || true
  exit "$REHEARSAL_RC"
fi

for marker in \
  'SPC001_MIGRATION_BASELINE=PASS' \
  'SPC001_FILTER_PRESET_BASELINE=PASS' \
  'SPC001_LEGACY_REFERENCE_REPAIR=PASS' \
  'SPC001_REFERENCE_REPAIR_LEDGER=PASS' \
  'SPC001_LEGACY_MONETARY_TOTALS=PASS' \
  'SPC001_PERSONAL_SPACE_MIGRATION=PASS' \
  'SPC001_SAME_SPACE_REFERENCES=PASS' \
  'SPC001_CAPTURE_PROVENANCE_MIGRATION=PASS' \
  'SPC001_FILTER_PRESET_REFERENCE_REPAIR=PASS' \
  'SPC001_FILTER_PRESET_REFERENCE_LEDGER=PASS' \
  'SPC001_FILTER_PRESET_REFERENCES=PASS'
do
  grep -F "$marker" "$REHEARSAL_REPORT" >/dev/null || {
    echo "SPC001_DB_ROLLBACK_REHEARSAL=FAIL missing_marker=$marker" >&2
    exit 1
  }
done
grep -Fx 'ROLLBACK' "$REHEARSAL_REPORT" >/dev/null || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL terminal_rollback_not_observed' >&2
  exit 1
}
echo 'atomic_rollback_program=PASS'

echo
echo '=== CLONE POST-ROLLBACK EQUIVALENCE ==='
spc001_fingerprint_clone "$CLONE_FP_AFTER"
cmp -s "$CLONE_FP_BEFORE" "$CLONE_FP_AFTER" || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL clone_table_state_changed_after_rollback' >&2
  diff -u "$CLONE_FP_BEFORE" "$CLONE_FP_AFTER" >&2 || true
  exit 1
}

spc001_clone_schema_dump "$CLONE_SCHEMA_AFTER_RAW"
spc001_normalize_schema_dump "$CLONE_SCHEMA_AFTER_RAW" "$CLONE_SCHEMA_AFTER"
cmp -s "$CLONE_SCHEMA_BEFORE" "$CLONE_SCHEMA_AFTER" || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL clone_schema_changed_after_rollback' >&2
  diff -u "$CLONE_SCHEMA_BEFORE" "$CLONE_SCHEMA_AFTER" >&2 || true
  exit 1
}

spc001_clone_psql_file "$ROOT/db/domain/SPC-001/308_migration_reference_repairability_preflight.sql" \
  > "$CLONE_REPAIRABILITY_AFTER" 2>&1
grep -Fx 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS' "$CLONE_REPAIRABILITY_AFTER" >/dev/null
cmp -s "$CLONE_REPAIRABILITY_BEFORE" "$CLONE_REPAIRABILITY_AFTER" || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL clone_repairability_changed_after_rollback' >&2
  exit 1
}

set +e
spc001_clone_psql_file "$ROOT/db/domain/SPC-001/305_migration_preflight.sql" \
  > "$CLONE_PREFLIGHT_AFTER" 2>&1
CLONE_STRICT_AFTER_RC=$?
set -e
[[ "$CLONE_STRICT_AFTER_RC" -eq "$CLONE_STRICT_BEFORE_RC" ]] || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL clone_strict_preflight_rc_changed' >&2
  exit 1
}
cmp -s "$CLONE_PREFLIGHT" "$CLONE_PREFLIGHT_AFTER" || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL clone_strict_preflight_changed_after_rollback' >&2
  diff -u "$CLONE_PREFLIGHT" "$CLONE_PREFLIGHT_AFTER" >&2 || true
  exit 1
}
echo 'clone_table_state_after_rollback=PASS'
echo 'clone_schema_after_rollback=PASS'
echo 'clone_legacy_contract_after_rollback=PASS'

echo
echo '=== DROP DISPOSABLE CLONE ==='
spc001_drop_clone
echo 'clone_drop=PASS'

echo
echo '=== LIVE POST-REHEARSAL READ-ONLY CHECK ==='
spc001_fingerprint_live "$LIVE_FP_AFTER"
cmp -s "$LIVE_FP_BEFORE" "$LIVE_FP_AFTER" || {
  echo 'SPC001_DB_ROLLBACK_REHEARSAL=FAIL live_table_state_changed_during_rehearsal' >&2
  diff -u "$LIVE_FP_BEFORE" "$LIVE_FP_AFTER" >&2 || true
  exit 1
}
echo 'live_table_state_unchanged=PASS'

cat > "$METADATA" <<EOF
HEAD=$HEAD_SHA
DB_RUNTIME_MODE=$UX022_DB_MODE
REHEARSAL_TARGET=DISPOSABLE_DATABASE_CLONE
BACKUP_SHA256=$BACKUP_SHA
ROLLBACK_BUNDLE_SHA256=$(sha256sum "$ROLLBACK_BUNDLE" | awk '{print $1}')
LIVE_DB_MUTATION=NONE
CLONE_DB_DROPPED=YES
COMMIT_FORBIDDEN=YES
EOF

rm -f "$CLONE_SCHEMA_BEFORE_RAW" "$CLONE_SCHEMA_AFTER_RAW"
(
  cd "$OUTPUT_DIR"
  sha256sum \
    spc001-migration-rollback.sql \
    live-pre-rehearsal.dump \
    live-pre-rehearsal.list \
    live-repairability.txt \
    live-table-fingerprint-before.txt \
    live-table-fingerprint-after.txt \
    clone-table-fingerprint-before.txt \
    clone-table-fingerprint-after.txt \
    clone-schema-before.sql \
    clone-schema-after.sql \
    clone-repairability-before.txt \
    clone-repairability-after.txt \
    clone-strict-preflight-before.txt \
    clone-strict-preflight-after.txt \
    rollback-rehearsal.txt \
    rehearsal-metadata.txt \
    > SHA256SUMS
)

echo
echo '=== REHEARSAL EVIDENCE ==='
cat "$METADATA"
cat "$MANIFEST"
echo "REHEARSAL_DIR=$OUTPUT_DIR"
echo 'LIVE_DB_MUTATION=NONE'
echo 'REHEARSAL_DB_MUTATION=DISPOSABLE_CLONE_ONLY'
echo 'N8N_IMPORT=NONE'
echo 'N8N_ACTIVATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_MUTATION=NONE'
echo 'SPC001_DB_ROLLBACK_REHEARSAL=PASS'
echo 'NEXT=prepare fresh durable backup + controlled live COMMIT gate; COMMIT is still forbidden by this script'
