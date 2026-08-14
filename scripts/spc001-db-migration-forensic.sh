#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUTPUT_DIR="/tmp/moneytrack-spc001-db-forensic"
if [[ "${1:-}" == "--output-dir" ]]; then
  [[ -n "${2:-}" ]] || { echo 'ERROR: --output-dir requires a value' >&2; exit 2; }
  OUTPUT_DIR="$2"
  shift 2
fi
[[ $# -eq 0 ]] || { echo "ERROR: unexpected arguments: $*" >&2; exit 2; }

for command_name in python3 sha256sum git; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "SPC001_DB_MIGRATION_FORENSIC=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain)" ]]; then
  echo 'SPC001_DB_MIGRATION_FORENSIC=FAIL dirty_checkout' >&2
  git status --short >&2
  exit 1
fi

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

COMMIT_BUNDLE="$OUTPUT_DIR/spc001-migration-commit.sql"
ROLLBACK_BUNDLE="$OUTPUT_DIR/spc001-migration-rollback.sql"
DIAGNOSTIC_REPORT="$OUTPUT_DIR/db-cross-user-diagnostic.txt"
PROVENANCE_REPORT="$OUTPUT_DIR/db-reference-provenance.txt"
PREFLIGHT_REPORT="$OUTPUT_DIR/db-preflight.txt"
MANIFEST="$OUTPUT_DIR/SHA256SUMS"

echo '=== SPC-001D DB MIGRATION FORENSIC ==='
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'MUTATION_POLICY=READ_ONLY_PREFLIGHT_AND_LOCAL_BUNDLE_BUILD'

python3 "$ROOT/scripts/spc001-build-db-migration.py" \
  --output "$COMMIT_BUNDLE" \
  --final commit
python3 "$ROOT/scripts/spc001-build-db-migration.py" \
  --output "$ROLLBACK_BUNDLE" \
  --final rollback

echo 'atomic_bundle_build=PASS'

python3 - "$COMMIT_BUNDLE" "$ROLLBACK_BUNDLE" <<'PY'
from pathlib import Path
import re
import sys

commit=Path(sys.argv[1]).read_text(encoding='utf-8')
rollback=Path(sys.argv[2]).read_text(encoding='utf-8')

def tx_lines(text):
    return [line.strip().lower() for line in text.splitlines()
            if re.fullmatch(r'\s*(?:begin|commit|rollback)\s*;\s*', line, re.I)]

assert tx_lines(commit)==['begin;','commit;'], tx_lines(commit)
assert tx_lines(rollback)==['begin;','rollback;'], tx_lines(rollback)
assert 'SPC001_MIGRATION_BASELINE=PASS' in commit
assert 'SPC001_ATOMIC_RECONCILIATION_FAILED' in commit
assert 'pg_advisory_xact_lock' in commit
assert commit.replace('\ncommit;\n','\nrollback;\n') == rollback
print('atomic_transaction_shape=PASS')
print('rollback_candidate=PASS')
PY

echo
echo '=== LIVE POSTGRESQL READ-ONLY CROSS-USER DIAGNOSTIC ==='
ux022_db_psql_file "$ROOT/db/domain/SPC-001/306_migration_cross_user_diagnostic.sql" \
  2>&1 | tee "$DIAGNOSTIC_REPORT"
grep -Fx 'SPC001_CROSS_USER_DIAGNOSTIC=BEGIN' "$DIAGNOSTIC_REPORT" >/dev/null
grep -Fx 'SPC001_CROSS_USER_DIAGNOSTIC=END' "$DIAGNOSTIC_REPORT" >/dev/null
echo 'cross_user_diagnostic=PASS'

echo
echo '=== LIVE POSTGRESQL READ-ONLY REFERENCE PROVENANCE ==='
ux022_db_psql_file "$ROOT/db/domain/SPC-001/307_migration_reference_provenance_diagnostic.sql" \
  2>&1 | tee "$PROVENANCE_REPORT"
grep -Fx 'SPC001_REFERENCE_PROVENANCE_DIAGNOSTIC=BEGIN' "$PROVENANCE_REPORT" >/dev/null
grep -Fx 'SPC001_REFERENCE_PROVENANCE_DIAGNOSTIC=END' "$PROVENANCE_REPORT" >/dev/null
echo 'reference_provenance_diagnostic=PASS'

echo
echo '=== LIVE POSTGRESQL READ-ONLY PREFLIGHT ==='
set +e
ux022_db_psql_file "$ROOT/db/domain/SPC-001/305_migration_preflight.sql" \
  2>&1 | tee "$PREFLIGHT_REPORT"
PREFLIGHT_RC=${PIPESTATUS[0]}
set -e

(
  cd "$OUTPUT_DIR"
  sha256sum \
    spc001-migration-commit.sql \
    spc001-migration-rollback.sql \
    db-cross-user-diagnostic.txt \
    db-reference-provenance.txt \
    db-preflight.txt \
    > SHA256SUMS
)

echo
echo '=== FORENSIC ARTIFACTS ==='
cat "$MANIFEST"
echo "FORENSIC_DIR=$OUTPUT_DIR"
echo 'DB_MUTATION=NONE'
echo 'N8N_IMPORT=NONE'
echo 'N8N_ACTIVATION=NONE'
echo 'PREVIEW_MUTATION=NONE'
echo 'PRODUCTION_MUTATION=NONE'

if [[ "$PREFLIGHT_RC" -ne 0 ]]; then
  echo "SPC001_DB_PREFLIGHT_RC=$PREFLIGHT_RC"
  echo 'SPC001_DB_MIGRATION_FORENSIC=FAIL live_db_preflight'
  echo 'NEXT=classify reference provenance before any migration repair'
  exit "$PREFLIGHT_RC"
fi

grep -Fx 'SPC001_DB_PREFLIGHT=PASS' "$PREFLIGHT_REPORT" >/dev/null
echo 'live_db_preflight=PASS'
echo 'SPC001_DB_MIGRATION_FORENSIC=PASS'
echo 'NEXT=prepare controlled DB backup + atomic apply gate'
