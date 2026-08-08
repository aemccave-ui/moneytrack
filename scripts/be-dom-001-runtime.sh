#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQL_DIR="$ROOT_DIR/db/domain/BE-DOM-001"

INSTALL_SQL="$SQL_DIR/001_finance_read_models.sql"
VERIFY_SQL="$SQL_DIR/002_verify_finance_read_models.sql"
ROLLBACK_SQL="$SQL_DIR/900_rollback_finance_read_models.sql"

usage() {
  cat <<'EOF'
Usage:
  DATABASE_URL='postgresql://...' scripts/be-dom-001-runtime.sh install
  DATABASE_URL='postgresql://...' USER_ID=123 AS_OF=2026-08-08 scripts/be-dom-001-runtime.sh verify
  DATABASE_URL='postgresql://...' ALLOW_DB_MUTATION=1 scripts/be-dom-001-runtime.sh rollback

Safety:
  - DATABASE_URL is required and is never printed.
  - install/rollback require ALLOW_DB_MUTATION=1.
  - verify is read-only and requires USER_ID and AS_OF.
  - psql ON_ERROR_STOP is enabled for every action.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 127
  }
}

require_file() {
  [[ -f "$1" ]] || {
    echo "Required file not found: $1" >&2
    exit 2
  }
}

require_database_url() {
  [[ -n "${DATABASE_URL:-}" ]] || {
    echo "DATABASE_URL is required" >&2
    exit 2
  }
}

require_mutation_opt_in() {
  [[ "${ALLOW_DB_MUTATION:-}" == "1" ]] || {
    echo "Refusing database mutation. Set ALLOW_DB_MUTATION=1 explicitly." >&2
    exit 3
  }
}

psql_base() {
  psql "$DATABASE_URL" \
    --no-psqlrc \
    --set=ON_ERROR_STOP=1 \
    "$@"
}

install_domain() {
  require_mutation_opt_in
  echo "Installing BE-DOM-001 finance read-model functions..."
  psql_base --file="$INSTALL_SQL"
  echo "Install completed. Run verify before any n8n cutover."
}

verify_domain() {
  [[ -n "${USER_ID:-}" ]] || {
    echo "USER_ID is required for verify" >&2
    exit 2
  }
  [[ "$USER_ID" =~ ^[0-9]+$ ]] || {
    echo "USER_ID must be an integer" >&2
    exit 2
  }
  [[ -n "${AS_OF:-}" ]] || {
    echo "AS_OF is required for verify (YYYY-MM-DD)" >&2
    exit 2
  }
  [[ "$AS_OF" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    echo "AS_OF must use YYYY-MM-DD format" >&2
    exit 2
  }

  echo "Running BE-DOM-001 parity verification for user_id=$USER_ID as_of=$AS_OF..."
  psql_base \
    --set=user_id="$USER_ID" \
    --set=as_of="$AS_OF" \
    --file="$VERIFY_SQL"
  echo "Verification script completed without SQL errors. Inspect all parity result rows before cutover."
}

rollback_domain() {
  require_mutation_opt_in
  echo "Rolling back BE-DOM-001 finance read-model functions..."
  psql_base --file="$ROLLBACK_SQL"
  echo "Rollback completed."
}

main() {
  require_command psql
  require_database_url
  require_file "$INSTALL_SQL"
  require_file "$VERIFY_SQL"
  require_file "$ROLLBACK_SQL"

  case "${1:-}" in
    install)
      install_domain
      ;;
    verify)
      verify_domain
      ;;
    rollback)
      rollback_domain
      ;;
    -h|--help|help|"")
      usage
      ;;
    *)
      echo "Unknown action: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
