#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/opt/moneytrack/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BACKUP_ROOT/$STAMP"
N8N_VOLUME_SOURCE="$(docker inspect n8n --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}')"

umask 077
mkdir -p "$OUT"
chmod 700 "$BACKUP_ROOT" "$OUT"

cleanup_failed() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "backup_result=FAIL output=$OUT"
  fi
  exit "$rc"
}
trap cleanup_failed EXIT

for c in n8n postgres moneytrack-db; do
  docker inspect "$c" >/dev/null 2>&1 || { echo "required_container_missing=$c"; exit 1; }
  [ "$(docker inspect "$c" --format '{{.State.Running}}')" = "true" ] || { echo "required_container_not_running=$c"; exit 1; }
done

[ -n "$N8N_VOLUME_SOURCE" ] && [ -d "$N8N_VOLUME_SOURCE" ] || {
  echo "n8n_persistent_volume_source=FAIL"
  exit 1
}

echo "=== PROD-H2 BACKUP START ==="
echo "backup_output=$OUT"

# Database dumps use local Unix sockets inside each production DB container.
# No database password is printed or copied into the backup manifest.
docker exec moneytrack-db pg_dump -U moneytrack -d moneytrack -Fc > "$OUT/moneytrack.dump"
docker exec postgres pg_dump -U n8n -d n8n -Fc > "$OUT/n8n-metadata.dump"

[ -s "$OUT/moneytrack.dump" ] || { echo "moneytrack_dump=EMPTY"; exit 1; }
[ -s "$OUT/n8n-metadata.dump" ] || { echo "n8n_metadata_dump=EMPTY"; exit 1; }
chmod 600 "$OUT/moneytrack.dump" "$OUT/n8n-metadata.dump"

echo "moneytrack_dump=PASS bytes=$(stat -c '%s' "$OUT/moneytrack.dump")"
echo "n8n_metadata_dump=PASS bytes=$(stat -c '%s' "$OUT/n8n-metadata.dump")"

# n8n persistent state contains recovery-critical config/encryption material.
tar -C "$N8N_VOLUME_SOURCE" -czf "$OUT/n8n-data.tar.gz" .
chmod 600 "$OUT/n8n-data.tar.gz"
[ -s "$OUT/n8n-data.tar.gz" ] || { echo "n8n_data_archive=EMPTY"; exit 1; }
echo "n8n_data_archive=PASS bytes=$(stat -c '%s' "$OUT/n8n-data.tar.gz")"

# Recovery configuration is sensitive and is kept only inside the protected backup set.
# PROD-H hardening overlays and protected Compose interpolation snapshots are included
# when present so clean recreation does not depend on a Git checkout or transient shell env.
config_inputs=()
for p in \
  /root/stack/n8n/docker-compose.yml \
  /root/stack/n8n/docker-compose.prod-h.yml \
  /root/stack/n8n/docker-compose.sec001.yml \
  /root/stack/n8n/compose-interpolation.prod-h.sh \
  /opt/moneytrack/postgres/docker-compose.yml \
  /opt/moneytrack/postgres/docker-compose.prod-h.yml \
  /opt/moneytrack/postgres/compose-interpolation.prod-h.sh \
  /home/adm_mt/moneytrack-automation/config/n8n.env; do
  [ -f "$p" ] && config_inputs+=("$p")
done

if [ "${#config_inputs[@]}" -gt 0 ]; then
  tar -czf "$OUT/runtime-config.tar.gz" "${config_inputs[@]}"
  chmod 600 "$OUT/runtime-config.tar.gz"
  echo "runtime_config_archive=PASS files=${#config_inputs[@]} bytes=$(stat -c '%s' "$OUT/runtime-config.tar.gz")"
else
  echo "runtime_config_archive=SKIP no_inputs"
fi

# Write manifest without secret values.
{
  echo "created_utc=$STAMP"
  echo "host=$(hostname)"
  echo "moneytrack_db_image=$(docker inspect moneytrack-db --format '{{.Config.Image}}')"
  echo "moneytrack_db_image_id=$(docker inspect moneytrack-db --format '{{.Image}}')"
  echo "n8n_db_image=$(docker inspect postgres --format '{{.Config.Image}}')"
  echo "n8n_db_image_id=$(docker inspect postgres --format '{{.Image}}')"
  echo "n8n_image=$(docker inspect n8n --format '{{.Config.Image}}')"
  echo "n8n_image_id=$(docker inspect n8n --format '{{.Image}}')"
  echo "n8n_version=$(docker exec n8n n8n --version 2>/dev/null | tail -n1)"
  echo "moneytrack_postgres_version=$(docker exec moneytrack-db postgres --version | sed 's/[[:space:]]\+/ /g')"
  echo "n8n_postgres_version=$(docker exec postgres postgres --version | sed 's/[[:space:]]\+/ /g')"
} > "$OUT/manifest.txt"
chmod 600 "$OUT/manifest.txt"

(
  cd "$OUT"
  sha256sum moneytrack.dump n8n-metadata.dump n8n-data.tar.gz manifest.txt > SHA256SUMS
  if [ -f runtime-config.tar.gz ]; then
    sha256sum runtime-config.tar.gz >> SHA256SUMS
  fi
)
chmod 600 "$OUT/SHA256SUMS"

touch "$OUT/COMPLETE"
chmod 600 "$OUT/COMPLETE"

sync
trap - EXIT

echo "backup_hash_manifest=PASS"
echo "backup_complete_marker=PASS"
echo "backup_result=PASS output=$OUT"
echo "=== PROD-H2 BACKUP COMPLETE ==="
