#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/opt/moneytrack/backups}"
BACKUP_DIR="${1:-}"

if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -exec test -f '{}/COMPLETE' ';' -print 2>/dev/null | sort | tail -n1)"
fi

[ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || { echo "backup_dir=NOT_FOUND"; exit 1; }
[ -f "$BACKUP_DIR/COMPLETE" ] || { echo "backup_complete_marker=MISSING"; exit 1; }

for f in moneytrack.dump n8n-metadata.dump n8n-data.tar.gz manifest.txt SHA256SUMS; do
  [ -s "$BACKUP_DIR/$f" ] || { echo "required_backup_file_missing_or_empty=$f"; exit 1; }
done

ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
MT_C="moneytrack-restore-verify-$ID"
N8N_C="n8n-restore-verify-$ID"
TMP="$(mktemp -d /tmp/moneytrack-restore-verify.XXXXXX)"
VERIFY_PASSWORD="prod-h2-local-verify-$ID"

cleanup() {
  docker rm -f "$MT_C" "$N8N_C" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_pg() {
  local c="$1"
  local i
  for i in $(seq 1 60); do
    if docker exec "$c" pg_isready -U postgres -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "=== PROD-H2 ISOLATED RESTORE VERIFY START ==="
echo "backup_dir=$BACKUP_DIR"

(
  cd "$BACKUP_DIR"
  sha256sum -c SHA256SUMS
)
echo "backup_hash_verification=PASS"

# Rehearsal uses the exact image object already running in production, not the mutable postgres:16 tag.
PG_IMAGE_ID="$(docker inspect moneytrack-db --format '{{.Image}}')"
[ -n "$PG_IMAGE_ID" ] || { echo "postgres_image_resolution=FAIL"; exit 1; }
echo "restore_postgres_image_id=$PG_IMAGE_ID"

docker image inspect "$PG_IMAGE_ID" >/dev/null 2>&1 || { echo "restore_postgres_image_local=FAIL"; exit 1; }

docker run --pull=never -d --name "$MT_C" \
  -e POSTGRES_PASSWORD="$VERIFY_PASSWORD" \
  "$PG_IMAGE_ID" >/dev/null

docker run --pull=never -d --name "$N8N_C" \
  -e POSTGRES_PASSWORD="$VERIFY_PASSWORD" \
  "$PG_IMAGE_ID" >/dev/null

wait_pg "$MT_C" || { echo "moneytrack_restore_container_readiness=FAIL"; exit 1; }
wait_pg "$N8N_C" || { echo "n8n_restore_container_readiness=FAIL"; exit 1; }
echo "isolated_restore_containers=READY host_ports=NONE"

docker cp "$BACKUP_DIR/moneytrack.dump" "$MT_C:/tmp/moneytrack.dump"
docker cp "$BACKUP_DIR/n8n-metadata.dump" "$N8N_C:/tmp/n8n-metadata.dump"

docker exec "$MT_C" createdb -U postgres moneytrack_restore
docker exec "$MT_C" pg_restore -U postgres -d moneytrack_restore --no-owner --no-privileges /tmp/moneytrack.dump

docker exec "$N8N_C" createdb -U postgres n8n_restore
docker exec "$N8N_C" pg_restore -U postgres -d n8n_restore --no-owner --no-privileges /tmp/n8n-metadata.dump

echo "postgres_restore_commands=PASS"

MT_TX="$(docker exec "$MT_C" psql -U postgres -d moneytrack_restore -Atc "select to_regclass('moneytrack.transactions') is not null")"
MT_USER="$(docker exec "$MT_C" psql -U postgres -d moneytrack_restore -Atc "select to_regclass('moneytrack.app_users') is not null")"
MT_FN="$(docker exec "$MT_C" psql -U postgres -d moneytrack_restore -Atc "select to_regprocedure('moneytrack.finance_delete_transaction_v1(bigint,bigint)') is not null")"
MT_TABLES="$(docker exec "$MT_C" psql -U postgres -d moneytrack_restore -Atc "select count(*) from information_schema.tables where table_schema='moneytrack'")"

[ "$MT_TX" = "t" ] || { echo "moneytrack_transactions_table_restore=FAIL"; exit 1; }
[ "$MT_USER" = "t" ] || { echo "moneytrack_app_users_table_restore=FAIL"; exit 1; }
[ "$MT_FN" = "t" ] || { echo "moneytrack_domain_function_restore=FAIL"; exit 1; }
[ "${MT_TABLES:-0}" -gt 0 ] || { echo "moneytrack_schema_table_count=FAIL"; exit 1; }
echo "moneytrack_restore_schema=PASS table_count=$MT_TABLES"

N8N_TABLES="$(docker exec "$N8N_C" psql -U postgres -d n8n_restore -Atc "select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'")"
N8N_WORKFLOW="$(docker exec "$N8N_C" psql -U postgres -d n8n_restore -Atc "select to_regclass('public.workflow_entity') is not null")"
[ "${N8N_TABLES:-0}" -gt 0 ] || { echo "n8n_schema_table_count=FAIL"; exit 1; }
[ "$N8N_WORKFLOW" = "t" ] || { echo "n8n_workflow_entity_restore=FAIL"; exit 1; }
echo "n8n_metadata_restore_schema=PASS table_count=$N8N_TABLES"

mkdir -p "$TMP/n8n-data"
tar -C "$TMP/n8n-data" -xzf "$BACKUP_DIR/n8n-data.tar.gz"
[ -f "$TMP/n8n-data/config" ] || { echo "restored_n8n_config_present=FAIL"; exit 1; }

python3 - "$TMP/n8n-data/config" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
key = data.get('encryptionKey')
if not isinstance(key, str) or not key:
    raise SystemExit('restored_n8n_encryption_key_present=FAIL')
print('restored_n8n_encryption_key_present=PASS value_not_printed=PASS')
PY

# Reassert production runtime after isolated rehearsal.
docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack >/dev/null
docker exec postgres pg_isready -U n8n -d n8n >/dev/null
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null

echo "production_moneytrack_db_health=PASS"
echo "production_n8n_db_health=PASS"
echo "production_n8n_health=PASS"
echo "temporary_restore_resources_cleanup=ARMED"
echo "=== PROD-H2 ISOLATED RESTORE VERIFY PASS ==="
