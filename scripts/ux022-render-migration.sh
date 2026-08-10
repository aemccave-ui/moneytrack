#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files=(
  "$ROOT/db/domain/UX-022/010_filter_presets.sql"
  "$ROOT/db/domain/UX-022/020_account_lifecycle.sql"
  "$ROOT/db/domain/UX-022/025_account_lifecycle_hardening.sql"
  "$ROOT/db/domain/UX-022/030_accounts_explorer_read_models.sql"
  "$ROOT/db/domain/UX-022/035_accounts_explorer_read_model_hardening.sql"
  "$ROOT/db/domain/UX-022/040_grouping_account_invariant.sql"
)

for file in "${files[@]}"; do
  test -s "$file" || {
    echo "ux022_migration_source_missing=$file" >&2
    exit 1
  }
  # Stored migrations follow repository convention with their own BEGIN/COMMIT.
  # The caller owns the surrounding transaction so validation and persistent apply
  # execute byte-for-byte the same migration body.
  sed -E '/^[[:space:]]*(begin|commit);[[:space:]]*$/Id' "$file"
done
