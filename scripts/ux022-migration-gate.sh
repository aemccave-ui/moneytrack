#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DATABASE_URL:?DATABASE_URL is required}"

files=(
  "$ROOT/db/domain/UX-022/010_filter_presets.sql"
  "$ROOT/db/domain/UX-022/020_account_lifecycle.sql"
  "$ROOT/db/domain/UX-022/025_account_lifecycle_hardening.sql"
  "$ROOT/db/domain/UX-022/030_accounts_explorer_read_models.sql"
  "$ROOT/db/domain/UX-022/035_accounts_explorer_read_model_hardening.sql"
)
verifiers=(
  "$ROOT/db/domain/UX-022/900_verify_contract.sql"
  "$ROOT/db/domain/UX-022/905_reference_inventory.sql"
)

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  echo 'begin;'
  for file in "${files[@]}"; do
    # Stored migrations follow repository convention with their own BEGIN/COMMIT.
    # Validation strips those two transaction markers so the entire candidate can
    # execute against the real schema and then be rolled back without persistence.
    sed -E '/^[[:space:]]*(begin|commit);[[:space:]]*$/Id' "$file"
  done
  for verify in "${verifiers[@]}"; do
    cat "$verify"
  done
  echo 'rollback;'
} > "$tmp"

psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmp"
echo 'migration_validation_gate=PASS'
