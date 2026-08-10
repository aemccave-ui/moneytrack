#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${DATABASE_URL:?DATABASE_URL is required}"

verifiers=(
  "$ROOT/db/domain/UX-022/900_verify_contract.sql"
  "$ROOT/db/domain/UX-022/905_reference_inventory.sql"
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

psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$tmp"
echo 'migration_validation_gate=PASS'
