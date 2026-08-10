#!/usr/bin/env bash
# Shared PostgreSQL runtime adapter for UX-022 gates.
#
# Preferred mode is a host PostgreSQL client with DATABASE_URL. When the host only
# has pg_wrapper (or no PostgreSQL client at all), fall back to the canonical
# MoneyTrack PostgreSQL container and its existing POSTGRES_* environment.

UX022_DB_CONTAINER="${MONEYTRACK_DB_CONTAINER:-moneytrack-db}"
UX022_DB_MODE=""

ux022_db_init() {
  if [[ -n "${DATABASE_URL:-}" ]] \
    && psql --version >/dev/null 2>&1 \
    && pg_dump --version >/dev/null 2>&1; then
    UX022_DB_MODE="database_url"
    return 0
  fi

  command -v docker >/dev/null 2>&1 || {
    echo 'db_runtime=FAIL no_usable_host_client_and_docker_missing' >&2
    return 1
  }

  docker inspect "$UX022_DB_CONTAINER" >/dev/null 2>&1 || {
    echo "db_runtime=FAIL db_container=$UX022_DB_CONTAINER" >&2
    return 1
  }

  docker exec "$UX022_DB_CONTAINER" sh -ceu '
    command -v psql >/dev/null
    command -v pg_dump >/dev/null
    : "${POSTGRES_USER:?POSTGRES_USER is required in DB container}"
    : "${POSTGRES_DB:?POSTGRES_DB is required in DB container}"
    : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required in DB container}"
  ' >/dev/null

  UX022_DB_MODE="container"
}

ux022_db_psql_file() {
  local file="$1"
  [[ -n "$UX022_DB_MODE" ]] || {
    echo 'db_runtime=FAIL not_initialized' >&2
    return 1
  }

  case "$UX022_DB_MODE" in
    database_url)
      psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$file"
      ;;
    container)
      docker exec -i "$UX022_DB_CONTAINER" sh -ceu '
        export PGPASSWORD="$POSTGRES_PASSWORD"
        exec psql -X \
          -h 127.0.0.1 \
          -U "$POSTGRES_USER" \
          -d "$POSTGRES_DB" \
          -v ON_ERROR_STOP=1
      ' < "$file"
      ;;
    *)
      echo "db_runtime=FAIL unknown_mode=$UX022_DB_MODE" >&2
      return 1
      ;;
  esac
}

ux022_db_pg_dump_schema() {
  local schema="$1"
  local output="$2"
  [[ -n "$UX022_DB_MODE" ]] || {
    echo 'db_runtime=FAIL not_initialized' >&2
    return 1
  }

  case "$UX022_DB_MODE" in
    database_url)
      pg_dump "$DATABASE_URL" \
        --schema="$schema" \
        --format=custom \
        --file="$output"
      ;;
    container)
      docker exec "$UX022_DB_CONTAINER" sh -ceu '
        export PGPASSWORD="$POSTGRES_PASSWORD"
        exec pg_dump \
          -h 127.0.0.1 \
          -U "$POSTGRES_USER" \
          -d "$POSTGRES_DB" \
          --schema="$1" \
          --format=custom
      ' sh "$schema" > "$output"
      ;;
    *)
      echo "db_runtime=FAIL unknown_mode=$UX022_DB_MODE" >&2
      return 1
      ;;
  esac
}
