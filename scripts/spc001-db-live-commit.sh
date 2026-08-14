#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR=""
REHEARSAL_DIR=""
EXPECTED_HEAD=""
APPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      [[ -n "${2:-}" ]] || { echo 'ERROR: --output-dir requires a value' >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --rehearsal-dir)
      [[ -n "${2:-}" ]] || { echo 'ERROR: --rehearsal-dir requires a value' >&2; exit 2; }
      REHEARSAL_DIR="$2"
      shift 2
      ;;
    --expected-head)
      [[ -n "${2:-}" ]] || { echo 'ERROR: --expected-head requires a value' >&2; exit 2; }
      EXPECTED_HEAD="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    *)
      echo "ERROR: unexpected argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ "$APPLY" -eq 1 ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=REFUSED explicit_--apply_required' >&2
  exit 2
}
[[ -n "$OUTPUT_DIR" && -n "$REHEARSAL_DIR" && -n "$EXPECTED_HEAD" ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=REFUSED output_rehearsal_expected_head_required' >&2
  exit 2
}
[[ "$OUTPUT_DIR" = /* ]] || { echo 'ERROR: --output-dir must be absolute' >&2; exit 2; }
case "$OUTPUT_DIR" in
  /tmp|/tmp/*)
    echo 'SPC001_DB_LIVE_COMMIT=REFUSED durable_output_required_not_tmp' >&2
    exit 2
    ;;
esac
[[ -d "$REHEARSAL_DIR" ]] || { echo 'ERROR: rehearsal directory missing' >&2; exit 2; }
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: output path already exists: $OUTPUT_DIR" >&2; exit 2; }

for command_name in python3 sha256sum git docker cmp grep awk sed stat cp sync tee; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "SPC001_DB_LIVE_COMMIT=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo 'SPC001_DB_LIVE_COMMIT=FAIL dirty_checkout' >&2
  git status --short >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == "$EXPECTED_HEAD" ]] || {
  echo "SPC001_DB_LIVE_COMMIT=FAIL head_mismatch expected=$EXPECTED_HEAD actual=$HEAD_SHA" >&2
  exit 1
}

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init
[[ "$UX022_DB_MODE" == "container" ]] || {
  echo "SPC001_DB_LIVE_COMMIT=FAIL unsupported_db_runtime_mode=$UX022_DB_MODE" >&2
  exit 1
}

for required_container in "$UX022_DB_CONTAINER" n8n postgres; do
  docker inspect "$required_container" >/dev/null 2>&1 || {
    echo "SPC001_DB_LIVE_COMMIT=FAIL required_container_missing=$required_container" >&2
    exit 1
  }
done
[[ "$(docker inspect n8n --format '{{.State.Running}}')" == "true" ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL n8n_not_running_before_gate' >&2
  exit 1
}
[[ -f "$ROOT/scripts/prod-h2-backup-now.sh" ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL prod_h2_backup_script_missing' >&2
  exit 1
}

docker exec "$UX022_DB_CONTAINER" sh -ceu '
  command -v psql >/dev/null
  command -v pg_restore >/dev/null
  command -v createdb >/dev/null
  command -v dropdb >/dev/null
  : "${POSTGRES_USER:?POSTGRES_USER required}"
  : "${POSTGRES_DB:?POSTGRES_DB required}"
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"
' >/dev/null

umask 077
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

COMMIT_BUNDLE="$OUTPUT_DIR/spc001-migration-commit.sql"
ROLLBACK_BUNDLE="$OUTPUT_DIR/spc001-migration-rollback.sql"
LIVE_REPAIRABILITY_BEFORE="$OUTPUT_DIR/live-repairability-before.txt"
LIVE_REPAIRABILITY_PRE_APPLY="$OUTPUT_DIR/live-repairability-pre-apply.txt"
LIVE_FP_BEFORE="$OUTPUT_DIR/live-table-fingerprint-before.txt"
LIVE_FP_AFTER_BACKUP="$OUTPUT_DIR/live-table-fingerprint-after-backup.txt"
LIVE_FP_PRE_QUIESCE="$OUTPUT_DIR/live-table-fingerprint-pre-quiesce.txt"
LIVE_FP_QUIESCED="$OUTPUT_DIR/live-table-fingerprint-quiesced.txt"
LIVE_FP_AFTER="$OUTPUT_DIR/live-table-fingerprint-after.txt"
BACKUP_LOG="$OUTPUT_DIR/prod-h2-backup.log"
BACKUP_LIST="$OUTPUT_DIR/moneytrack-backup.list"
CLONE_COMMIT_REPORT="$OUTPUT_DIR/clone-commit-rehearsal.txt"
CLONE_POST_VERIFY="$OUTPUT_DIR/clone-post-migration-readonly.txt"
CLONE_VERIFY_090="$OUTPUT_DIR/clone-verify-090.txt"
CLONE_VERIFY_091="$OUTPUT_DIR/clone-verify-091.txt"
CLONE_VERIFY_190="$OUTPUT_DIR/clone-verify-190.txt"
CLONE_VERIFY_290="$OUTPUT_DIR/clone-verify-290.txt"
LIVE_COMMIT_REPORT="$OUTPUT_DIR/live-commit.txt"
LIVE_POST_VERIFY="$OUTPUT_DIR/live-post-migration-readonly.txt"
QUIESCENCE_REPORT="$OUTPUT_DIR/live-quiescence.txt"
METADATA="$OUTPUT_DIR/live-commit-metadata.txt"
MANIFEST="$OUTPUT_DIR/SHA256SUMS"

CLONE_DB="spc001_commit_${HEAD_SHA:0:8}_$$_${RANDOM}"
CLONE_CREATED=0
N8N_STOPPED_BY_GATE=0
N8N_RESTARTED=0

spc001_drop_clone() {
  if [[ "$CLONE_CREATED" -eq 1 ]]; then
    docker exec "$UX022_DB_CONTAINER" sh -ceu '
      export PGPASSWORD="$POSTGRES_PASSWORD"
      exec dropdb -h 127.0.0.1 -U "$POSTGRES_USER" --if-exists "$1"
    ' sh "$CLONE_DB" >/dev/null 2>&1 || true
    CLONE_CREATED=0
  fi
}

spc001_restart_n8n_if_needed() {
  if [[ "$N8N_STOPPED_BY_GATE" -eq 1 ]]; then
    docker start n8n >/dev/null 2>&1 || true
    N8N_STOPPED_BY_GATE=0
  fi
}

spc001_cleanup() {
  local rc=$?
  trap - EXIT
  spc001_drop_clone
  spc001_restart_n8n_if_needed
  if [[ "$rc" -ne 0 ]]; then
    echo "SPC001_DB_LIVE_COMMIT=FAIL rc=$rc output=$OUTPUT_DIR" >&2
  fi
  exit "$rc"
}
trap spc001_cleanup EXIT

spc001_clone_create() {
  docker exec "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec createdb -h 127.0.0.1 -U "$POSTGRES_USER" --template=template0 "$1"
  ' sh "$CLONE_DB"
  CLONE_CREATED=1
}

spc001_clone_restore() {
  local backup="$1"
  docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec pg_restore \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      -d "$1" \
      --exit-on-error \
      --single-transaction
  ' sh "$CLONE_DB" < "$backup"
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

spc001_require_migration_markers() {
  local report="$1"
  local marker
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
    grep -F "$marker" "$report" >/dev/null || {
      echo "SPC001_DB_LIVE_COMMIT=FAIL missing_migration_marker=$marker" >&2
      return 1
    }
  done
  grep -Fx 'COMMIT' "$report" >/dev/null || {
    echo 'SPC001_DB_LIVE_COMMIT=FAIL terminal_commit_not_observed' >&2
    return 1
  }
}

spc001_run_clone_verifier() {
  local sql="$1"
  local output="$2"
  local marker="$3"
  spc001_clone_psql_file "$sql" > "$output" 2>&1
  grep -F "$marker" "$output" >/dev/null || {
    echo "SPC001_DB_LIVE_COMMIT=FAIL clone_verifier_marker_missing=$marker" >&2
    return 1
  }
  grep -Fx 'ROLLBACK' "$output" >/dev/null || {
    echo "SPC001_DB_LIVE_COMMIT=FAIL clone_verifier_rollback_missing=$sql" >&2
    return 1
  }
}

spc001_check_no_active_transactions() {
  docker exec "$UX022_DB_CONTAINER" sh -ceu '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec psql -X \
      -h 127.0.0.1 \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      -Atc "select count(*) from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid() and backend_type='\''client backend'\'' and (state<>'\''idle'\'' or xact_start is not null);"
  '
}

echo '=== SPC-001D3 CONTROLLED LIVE DB COMMIT ==='
echo "HEAD=$HEAD_SHA"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'MUTATION_SCOPE=LIVE_MONEYTRACK_DB_ONLY'
echo 'N8N_WORKFLOW_MUTATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'

echo
echo '=== SOURCE / EXACT BUNDLES ==='
python3 "$ROOT/scripts/spc001-migration-source-gate.py"
python3 "$ROOT/scripts/spc001-repair-sql-static-gate.py"
python3 "$ROOT/scripts/spc001-build-db-migration.py" --output "$COMMIT_BUNDLE" --final commit
python3 "$ROOT/scripts/spc001-build-db-migration.py" --output "$ROLLBACK_BUNDLE" --final rollback

python3 - "$COMMIT_BUNDLE" "$ROLLBACK_BUNDLE" <<'PY'
from pathlib import Path
import re,sys
commit=Path(sys.argv[1]).read_text(encoding='utf-8')
rollback=Path(sys.argv[2]).read_text(encoding='utf-8')
def tx(text):
    return [line.strip().lower() for line in text.splitlines()
            if re.fullmatch(r'\s*(?:begin|commit|rollback)\s*;\s*',line,re.I)]
assert tx(commit)==['begin;','commit;'],tx(commit)
assert tx(rollback)==['begin;','rollback;'],tx(rollback)
assert commit.replace('\ncommit;\n','\nrollback;\n')==rollback
print('live_commit_bundle_exact_shape=PASS')
print('commit_rollback_same_program=PASS')
PY

COMMIT_SHA="$(sha256sum "$COMMIT_BUNDLE" | awk '{print $1}')"
ROLLBACK_SHA="$(sha256sum "$ROLLBACK_BUNDLE" | awk '{print $1}')"

echo
echo '=== ACCEPTED ROLLBACK REHEARSAL EVIDENCE ==='
for rehearsal_file in rehearsal-metadata.txt SHA256SUMS rollback-rehearsal.txt; do
  [[ -s "$REHEARSAL_DIR/$rehearsal_file" ]] || {
    echo "SPC001_DB_LIVE_COMMIT=FAIL rehearsal_evidence_missing=$rehearsal_file" >&2
    exit 1
  }
done
(
  cd "$REHEARSAL_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
REHEARSAL_ROLLBACK_SHA="$(awk -F= '/^ROLLBACK_BUNDLE_SHA256=/{print $2}' "$REHEARSAL_DIR/rehearsal-metadata.txt" | tail -n1)"
[[ "$REHEARSAL_ROLLBACK_SHA" == "$ROLLBACK_SHA" ]] || {
  echo "SPC001_DB_LIVE_COMMIT=FAIL unrehearsed_migration_program rehearsal=$REHEARSAL_ROLLBACK_SHA current=$ROLLBACK_SHA" >&2
  exit 1
}
grep -Fx 'LIVE_DB_MUTATION=NONE' "$REHEARSAL_DIR/rehearsal-metadata.txt" >/dev/null
grep -Fx 'CLONE_DB_DROPPED=YES' "$REHEARSAL_DIR/rehearsal-metadata.txt" >/dev/null
grep -Fx 'COMMIT_FORBIDDEN=YES' "$REHEARSAL_DIR/rehearsal-metadata.txt" >/dev/null
cp "$REHEARSAL_DIR/rehearsal-metadata.txt" "$OUTPUT_DIR/accepted-rehearsal-metadata.txt"
cp "$REHEARSAL_DIR/SHA256SUMS" "$OUTPUT_DIR/accepted-rehearsal-SHA256SUMS"
cp "$REHEARSAL_DIR/rollback-rehearsal.txt" "$OUTPUT_DIR/accepted-rollback-rehearsal.txt"
echo "accepted_rehearsal_rollback_sha256=$REHEARSAL_ROLLBACK_SHA"
echo 'accepted_rollback_rehearsal=PASS'

echo
echo '=== LIVE PRE-COMMIT READ-ONLY BASELINE ==='
ux022_db_psql_file "$ROOT/db/domain/SPC-001/308_migration_reference_repairability_preflight.sql" \
  > "$LIVE_REPAIRABILITY_BEFORE" 2>&1
grep -Fx 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS' "$LIVE_REPAIRABILITY_BEFORE" >/dev/null
spc001_fingerprint_live "$LIVE_FP_BEFORE"
echo 'live_repairability_before=PASS'
echo 'live_table_fingerprint_before=PASS'

echo
echo '=== FRESH DURABLE PROD-H2 BACKUP ==='
BACKUP_ROOT="$OUTPUT_DIR/prod-h2" bash "$ROOT/scripts/prod-h2-backup-now.sh" | tee "$BACKUP_LOG"
BACKUP_DIR="$(sed -n 's/^backup_result=PASS output=//p' "$BACKUP_LOG" | tail -n1)"
[[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL durable_backup_path_not_resolved' >&2
  exit 1
}
[[ -f "$BACKUP_DIR/COMPLETE" && -s "$BACKUP_DIR/moneytrack.dump" && -s "$BACKUP_DIR/SHA256SUMS" ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL durable_backup_incomplete' >&2
  exit 1
}
(
  cd "$BACKUP_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)
docker exec -i "$UX022_DB_CONTAINER" pg_restore --list < "$BACKUP_DIR/moneytrack.dump" > "$BACKUP_LIST"
[[ -s "$BACKUP_LIST" ]] || { echo 'SPC001_DB_LIVE_COMMIT=FAIL moneytrack_backup_archive_list_empty' >&2; exit 1; }
MONEYTRACK_BACKUP_SHA="$(awk '$2=="moneytrack.dump"{print $1}' "$BACKUP_DIR/SHA256SUMS" | tail -n1)"
[[ -n "$MONEYTRACK_BACKUP_SHA" ]] || { echo 'SPC001_DB_LIVE_COMMIT=FAIL moneytrack_backup_sha_missing' >&2; exit 1; }
spc001_fingerprint_live "$LIVE_FP_AFTER_BACKUP"
cmp -s "$LIVE_FP_BEFORE" "$LIVE_FP_AFTER_BACKUP" || {
  echo 'SPC001_DB_LIVE_COMMIT=BLOCKED live_changed_during_backup' >&2
  exit 1
}
echo "durable_backup_dir=$BACKUP_DIR"
echo "moneytrack_backup_sha256=$MONEYTRACK_BACKUP_SHA"
echo 'live_table_state_stable_during_backup=PASS'

echo
echo '=== FRESH BACKUP COMMIT REHEARSAL ON DISPOSABLE CLONE ==='
spc001_clone_create
spc001_clone_restore "$BACKUP_DIR/moneytrack.dump"
CLONE_FP_BASE="$OUTPUT_DIR/clone-table-fingerprint-from-backup.txt"
spc001_fingerprint_clone "$CLONE_FP_BASE"
cmp -s "$LIVE_FP_BEFORE" "$CLONE_FP_BASE" || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL restored_backup_table_fingerprint_mismatch' >&2
  exit 1
}
spc001_clone_psql_file "$ROOT/db/domain/SPC-001/308_migration_reference_repairability_preflight.sql" \
  > "$OUTPUT_DIR/clone-repairability-before.txt" 2>&1
grep -Fx 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS' "$OUTPUT_DIR/clone-repairability-before.txt" >/dev/null
spc001_clone_psql_file "$COMMIT_BUNDLE" > "$CLONE_COMMIT_REPORT" 2>&1
spc001_require_migration_markers "$CLONE_COMMIT_REPORT"
spc001_clone_psql_file "$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql" \
  > "$CLONE_POST_VERIFY" 2>&1
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$CLONE_POST_VERIFY" >/dev/null
spc001_run_clone_verifier "$ROOT/db/domain/SPC-001/090_verify_tenancy_foundation.sql" "$CLONE_VERIFY_090" 'TENANT_ISOLATION=PASS'
spc001_run_clone_verifier "$ROOT/db/domain/SPC-001/091_verify_space_uniqueness_bootstrap.sql" "$CLONE_VERIFY_091" 'NEW_USER_SPACE_BOOTSTRAP=PASS'
spc001_run_clone_verifier "$ROOT/db/domain/SPC-001/190_verify_space_lifecycle.sql" "$CLONE_VERIFY_190" 'SPACE_LIFECYCLE=PASS'
spc001_run_clone_verifier "$ROOT/db/domain/SPC-001/290_verify_capture_projection.sql" "$CLONE_VERIFY_290" 'CAPTURE_EVENT_MULTI_PROJECTION=PASS'
spc001_drop_clone
echo 'fresh_backup_commit_rehearsal=PASS'
echo 'clone_post_migration_readonly=PASS'
echo 'clone_090=PASS'
echo 'clone_091=PASS'
echo 'clone_190=PASS'
echo 'clone_290=PASS'
echo 'clone_drop=PASS'

echo
echo '=== LIVE PRE-APPLY STABILITY CHECK ==='
spc001_fingerprint_live "$LIVE_FP_PRE_QUIESCE"
cmp -s "$LIVE_FP_BEFORE" "$LIVE_FP_PRE_QUIESCE" || {
  echo 'SPC001_DB_LIVE_COMMIT=BLOCKED live_changed_after_backup_before_apply' >&2
  echo 'NEXT=rerun gate to produce a fresh backup from the new live state' >&2
  exit 1
}
ux022_db_psql_file "$ROOT/db/domain/SPC-001/308_migration_reference_repairability_preflight.sql" \
  > "$LIVE_REPAIRABILITY_PRE_APPLY" 2>&1
grep -Fx 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS' "$LIVE_REPAIRABILITY_PRE_APPLY" >/dev/null
cmp -s "$LIVE_REPAIRABILITY_BEFORE" "$LIVE_REPAIRABILITY_PRE_APPLY" || {
  echo 'SPC001_DB_LIVE_COMMIT=BLOCKED repairability_changed_before_apply' >&2
  exit 1
}
echo 'live_state_matches_fresh_backup_before_quiesce=PASS'
echo 'live_repairability_pre_apply=PASS'

echo
echo '=== QUIESCE N8N WRITER ==='
docker stop -t 30 n8n > "$OUTPUT_DIR/n8n-stop.txt"
N8N_STOPPED_BY_GATE=1
[[ "$(docker inspect n8n --format '{{.State.Running}}')" == "false" ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL n8n_did_not_stop' >&2
  exit 1
}
ACTIVE_TX="$(spc001_check_no_active_transactions)"
printf 'active_other_client_transactions=%s\n' "$ACTIVE_TX" > "$QUIESCENCE_REPORT"
[[ "$ACTIVE_TX" == "0" ]] || {
  echo "SPC001_DB_LIVE_COMMIT=BLOCKED active_other_client_transactions=$ACTIVE_TX" >&2
  exit 1
}
spc001_fingerprint_live "$LIVE_FP_QUIESCED"
cmp -s "$LIVE_FP_BEFORE" "$LIVE_FP_QUIESCED" || {
  echo 'SPC001_DB_LIVE_COMMIT=BLOCKED live_changed_while_entering_quiescence' >&2
  exit 1
}
echo 'n8n_writer_quiesced=PASS'
echo 'active_other_client_transactions=0'
echo 'live_state_matches_fresh_backup_after_quiesce=PASS'

echo
echo '=== APPLY EXACT ATOMIC COMMIT BUNDLE TO LIVE DB ==='
set +e
ux022_db_psql_file "$COMMIT_BUNDLE" > "$LIVE_COMMIT_REPORT" 2>&1
LIVE_COMMIT_RC=$?
set -e
if [[ "$LIVE_COMMIT_RC" -ne 0 ]]; then
  echo "SPC001_DB_LIVE_COMMIT=FAIL migration_rc=$LIVE_COMMIT_RC" >&2
  tail -n 160 "$LIVE_COMMIT_REPORT" >&2 || true
  exit "$LIVE_COMMIT_RC"
fi
spc001_require_migration_markers "$LIVE_COMMIT_REPORT"
echo 'atomic_live_commit_program=PASS'

echo
echo '=== LIVE POST-COMMIT READ-ONLY VERIFY ==='
ux022_db_psql_file "$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql" \
  > "$LIVE_POST_VERIFY" 2>&1
grep -Fx 'SPC001_LIVE_POST_MIGRATION_VERIFY=PASS' "$LIVE_POST_VERIFY" >/dev/null
spc001_fingerprint_live "$LIVE_FP_AFTER"
echo 'live_post_migration_readonly=PASS'
echo 'live_table_fingerprint_after=CAPTURED'

echo
echo '=== RESTORE N8N SERVICE ==='
docker start n8n > "$OUTPUT_DIR/n8n-start.txt"
N8N_STOPPED_BY_GATE=0
for _ in $(seq 1 30); do
  if [[ "$(docker inspect n8n --format '{{.State.Running}}')" == "true" ]]; then
    N8N_RESTARTED=1
    break
  fi
  sleep 1
done
[[ "$N8N_RESTARTED" -eq 1 ]] || {
  echo 'SPC001_DB_LIVE_COMMIT=FAIL n8n_restart_failed_after_commit' >&2
  exit 1
}
echo 'n8n_service_restart=PASS'

cat > "$METADATA" <<EOF
HEAD=$HEAD_SHA
DB_RUNTIME_MODE=$UX022_DB_MODE
ACCEPTED_REHEARSAL_ROLLBACK_SHA256=$REHEARSAL_ROLLBACK_SHA
COMMIT_BUNDLE_SHA256=$COMMIT_SHA
ROLLBACK_BUNDLE_SHA256=$ROLLBACK_SHA
DURABLE_BACKUP_DIR=$BACKUP_DIR
MONEYTRACK_BACKUP_SHA256=$MONEYTRACK_BACKUP_SHA
LIVE_DB_MUTATION=COMMIT_APPLIED
LIVE_POST_MIGRATION_READONLY=PASS
CLONE_COMMIT_REHEARSAL=PASS
CLONE_SYNTHETIC_VERIFIERS=PASS
N8N_SERVICE_RESTART=PASS
N8N_IMPORT=NONE
N8N_ACTIVATION=NONE
PREVIEW_MUTATION=NONE
PRODUCTION_FRONTEND_MUTATION=NONE
EOF
chmod 600 "$METADATA"

(
  cd "$OUTPUT_DIR"
  sha256sum \
    spc001-migration-commit.sql \
    spc001-migration-rollback.sql \
    accepted-rehearsal-metadata.txt \
    accepted-rehearsal-SHA256SUMS \
    accepted-rollback-rehearsal.txt \
    live-repairability-before.txt \
    live-repairability-pre-apply.txt \
    live-table-fingerprint-before.txt \
    live-table-fingerprint-after-backup.txt \
    live-table-fingerprint-pre-quiesce.txt \
    live-table-fingerprint-quiesced.txt \
    live-table-fingerprint-after.txt \
    moneytrack-backup.list \
    clone-table-fingerprint-from-backup.txt \
    clone-repairability-before.txt \
    clone-commit-rehearsal.txt \
    clone-post-migration-readonly.txt \
    clone-verify-090.txt \
    clone-verify-091.txt \
    clone-verify-190.txt \
    clone-verify-290.txt \
    live-commit.txt \
    live-post-migration-readonly.txt \
    live-quiescence.txt \
    live-commit-metadata.txt \
    prod-h2-backup.log \
    n8n-stop.txt \
    n8n-start.txt \
    > SHA256SUMS
)
chmod 600 "$MANIFEST"
sync

trap - EXIT
spc001_drop_clone
spc001_restart_n8n_if_needed

echo
echo '=== SPC-001D3 LIVE COMMIT EVIDENCE ==='
cat "$METADATA"
echo "COMMIT_EVIDENCE_DIR=$OUTPUT_DIR"
echo 'LIVE_DB_MUTATION=COMMIT_APPLIED'
echo 'N8N_IMPORT=NONE'
echo 'N8N_ACTIVATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'SPC001_DB_LIVE_COMMIT=PASS'
echo 'NEXT=controlled n8n candidate import/activation gate'