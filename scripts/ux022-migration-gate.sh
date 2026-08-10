#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

echo "db_runtime_mode=$UX022_DB_MODE"
if [[ "$UX022_DB_MODE" == "container" ]]; then
  echo "db_runtime_container=$UX022_DB_CONTAINER"
fi

verifiers=(
  "$ROOT/db/domain/UX-022/900_verify_contract.sql"
  "$ROOT/db/domain/UX-022/905_reference_inventory.sql"
  "$ROOT/db/domain/UX-022/910_verify_grouping_invariant.sql"
)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  echo 'begin;'
  bash "$ROOT/scripts/ux022-render-migration.sh"
  for verify in "${verifiers[@]}"; do
    cat "$verify"
  done
  echo 'rollback;'
} > "$tmp"

ux022_db_psql_file "$tmp"
echo 'migration_validation_gate=PASS'
