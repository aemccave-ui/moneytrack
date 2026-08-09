#!/usr/bin/env bash
set -euo pipefail

N8N_BASE="/root/stack/n8n/docker-compose.yml"
MT_BASE="/opt/moneytrack/postgres/docker-compose.yml"
N8N_OVERLAY="/root/stack/n8n/docker-compose.prod-h.yml"
MT_OVERLAY="/opt/moneytrack/postgres/docker-compose.prod-h.yml"
N8N_DIGEST="n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca"
PG_TAG="postgres:16.14"
MARKER="# moneytrack-prod-h3-managed-v1"
BACKUP_ROOT="/opt/moneytrack/backups"
ROLLBACK_N8N="moneytrack-rollback/n8n:prod-h3-pre"
ROLLBACK_PG="moneytrack-rollback/postgres:prod-h3-pre"

TMP="$(mktemp -d /tmp/moneytrack-prod-h3-cutover.XXXXXX)"
MUTATED=0
OVERLAYS_INSTALLED=0
HAD_N8N_OVERLAY=0
HAD_MT_OVERLAY=0

wait_pg() {
  local c="$1" user="$2" db="$3" i
  for i in $(seq 1 90); do
    if docker exec "$c" pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_n8n() {
  local i
  for i in $(seq 1 120); do
    if curl -fsS --max-time 3 http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restore_overlay_files() {
  if [ "$HAD_N8N_OVERLAY" -eq 1 ]; then
    cp -a "$TMP/n8n-overlay.before" "$N8N_OVERLAY"
  else
    rm -f "$N8N_OVERLAY"
  fi
  if [ "$HAD_MT_OVERLAY" -eq 1 ]; then
    cp -a "$TMP/mt-overlay.before" "$MT_OVERLAY"
  else
    rm -f "$MT_OVERLAY"
  fi
}

rollback_runtime() {
  echo "=== PROD-H3 AUTOMATIC ROLLBACK START ==="

  cat > "$TMP/n8n-rollback.yml" <<EOF
services:
  n8n:
    image: $ROLLBACK_N8N
  postgres:
    image: $ROLLBACK_PG
EOF
  cat > "$TMP/mt-rollback.yml" <<EOF
services:
  moneytrack-db:
    image: $ROLLBACK_PG
EOF

  docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$TMP/n8n-rollback.yml" up -d --no-deps --force-recreate postgres || true
  wait_pg postgres n8n n8n || true
  docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$TMP/n8n-rollback.yml" up -d --no-deps --force-recreate n8n || true
  wait_n8n || true
  docker compose -p "$MT_PROJECT" -f "$MT_BASE" -f "$TMP/mt-rollback.yml" up -d --no-deps --force-recreate moneytrack-db || true
  wait_pg moneytrack-db moneytrack moneytrack || true

  restore_overlay_files
  echo "automatic_rollback=COMPLETE"
  echo "=== PROD-H3 AUTOMATIC ROLLBACK END ==="
}

cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "prod_h3_cutover=FAIL rc=$rc"
    if [ "$MUTATED" -eq 1 ]; then
      rollback_runtime
    elif [ "$OVERLAYS_INSTALLED" -eq 1 ]; then
      restore_overlay_files
    fi
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

for c in docker curl sha256sum grep awk sed find; do
  command -v "$c" >/dev/null 2>&1 || { echo "required_command_missing=$c"; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "docker_compose_plugin=FAIL"; exit 1; }

echo "=== PROD-H3 RUNTIME HARDENING CUTOVER START ==="

# Recovery gate immediately before mutation.
LATEST_BACKUP="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -exec test -f '{}/COMPLETE' ';' -print 2>/dev/null | sort | tail -n1)"
[ -n "$LATEST_BACKUP" ] || { echo "latest_complete_backup=FAIL"; exit 1; }
(
  cd "$LATEST_BACKUP"
  sha256sum -c SHA256SUMS >/dev/null
)
echo "recovery_gate=PASS backup=$LATEST_BACKUP"

for f in "$N8N_BASE" "$MT_BASE"; do
  [ -f "$f" ] || { echo "compose_base_missing=$f"; exit 1; }
done

N8N_PROJECT="$(docker inspect n8n --format '{{index .Config.Labels "com.docker.compose.project"}}')"
MT_PROJECT="$(docker inspect moneytrack-db --format '{{index .Config.Labels "com.docker.compose.project"}}')"
[ -n "$N8N_PROJECT" ] && [ -n "$MT_PROJECT" ] || { echo "compose_project_resolution=FAIL"; exit 1; }

N8N_VER_BEFORE="$(docker exec n8n n8n --version 2>/dev/null | tail -n1)"
PG_N8N_VER_BEFORE="$(docker exec postgres postgres --version | awk '{print $3}')"
PG_MT_VER_BEFORE="$(docker exec moneytrack-db postgres --version | awk '{print $3}')"
[ "$N8N_VER_BEFORE" = "2.22.5" ] || { echo "n8n_runtime_drift=FAIL actual=$N8N_VER_BEFORE"; exit 1; }
[ "$PG_N8N_VER_BEFORE" = "16.14" ] || { echo "n8n_postgres_runtime_drift=FAIL actual=$PG_N8N_VER_BEFORE"; exit 1; }
[ "$PG_MT_VER_BEFORE" = "16.14" ] || { echo "moneytrack_postgres_runtime_drift=FAIL actual=$PG_MT_VER_BEFORE"; exit 1; }
echo "runtime_version_gate=PASS"

N8N_MOUNT_BEFORE="$(docker inspect n8n --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}')"
PG_MOUNT_BEFORE="$(docker inspect postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"
MT_MOUNT_BEFORE="$(docker inspect moneytrack-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"

# Local rollback aliases point at the exact currently running images.
docker tag "$(docker inspect n8n --format '{{.Image}}')" "$ROLLBACK_N8N"
docker tag "$(docker inspect postgres --format '{{.Image}}')" "$ROLLBACK_PG"
echo "rollback_images_tagged=PASS"

# Pull target references before touching production containers.
docker pull "$N8N_DIGEST" >/dev/null
docker pull "$PG_TAG" >/dev/null

N8N_TARGET_VER="$(docker run --rm --entrypoint n8n "$N8N_DIGEST" --version 2>/dev/null | tail -n1)"
PG_TARGET_VER="$(docker run --rm --entrypoint postgres "$PG_TAG" --version 2>/dev/null | awk '{print $3}')"
[ "$N8N_TARGET_VER" = "2.22.5" ] || { echo "n8n_target_version=FAIL actual=$N8N_TARGET_VER"; exit 1; }
[ "$PG_TARGET_VER" = "16.14" ] || { echo "postgres_target_version=FAIL actual=$PG_TARGET_VER"; exit 1; }
echo "target_image_version_gate=PASS n8n=$N8N_TARGET_VER postgres=$PG_TARGET_VER"

cat > "$TMP/n8n-overlay.yml" <<EOF
$MARKER
services:
  n8n:
    image: $N8N_DIGEST
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
  postgres:
    image: $PG_TAG
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
EOF

cat > "$TMP/mt-overlay.yml" <<EOF
$MARKER
services:
  moneytrack-db:
    image: $PG_TAG
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"
EOF

# Validate candidate merge before installing overlays.
docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$TMP/n8n-overlay.yml" config >/dev/null
docker compose -p "$MT_PROJECT" -f "$MT_BASE" -f "$TMP/mt-overlay.yml" config >/dev/null
echo "candidate_compose_validation=PASS"

if [ -e "$N8N_OVERLAY" ]; then
  grep -Fxq "$MARKER" "$N8N_OVERLAY" || { echo "existing_unmanaged_overlay=FAIL path=$N8N_OVERLAY"; exit 1; }
  cp -a "$N8N_OVERLAY" "$TMP/n8n-overlay.before"
  HAD_N8N_OVERLAY=1
fi
if [ -e "$MT_OVERLAY" ]; then
  grep -Fxq "$MARKER" "$MT_OVERLAY" || { echo "existing_unmanaged_overlay=FAIL path=$MT_OVERLAY"; exit 1; }
  cp -a "$MT_OVERLAY" "$TMP/mt-overlay.before"
  HAD_MT_OVERLAY=1
fi

install -m 0644 "$TMP/n8n-overlay.yml" "$N8N_OVERLAY"
install -m 0644 "$TMP/mt-overlay.yml" "$MT_OVERLAY"
OVERLAYS_INSTALLED=1

echo "managed_overlays_installed=PASS"

# Re-render installed configuration exactly as operations will use it.
docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$N8N_OVERLAY" config >/dev/null
docker compose -p "$MT_PROJECT" -f "$MT_BASE" -f "$MT_OVERLAY" config >/dev/null
echo "installed_compose_validation=PASS"

MUTATED=1

# Recreate n8n metadata DB first, then n8n, then MoneyTrack DB.
docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$N8N_OVERLAY" up -d --no-deps --force-recreate postgres
wait_pg postgres n8n n8n || { echo "n8n_postgres_post_cutover_health=FAIL"; exit 1; }
echo "n8n_postgres_recreate=PASS"

docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$N8N_OVERLAY" up -d --no-deps --force-recreate n8n
wait_n8n || { echo "n8n_post_cutover_health=FAIL"; exit 1; }
echo "n8n_recreate=PASS"

docker compose -p "$MT_PROJECT" -f "$MT_BASE" -f "$MT_OVERLAY" up -d --no-deps --force-recreate moneytrack-db
wait_pg moneytrack-db moneytrack moneytrack || { echo "moneytrack_db_post_cutover_health=FAIL"; exit 1; }
echo "moneytrack_db_recreate=PASS"

# Runtime pins and versions.
[ "$(docker inspect n8n --format '{{.Config.Image}}')" = "$N8N_DIGEST" ] || { echo "n8n_image_pin=FAIL"; exit 1; }
[ "$(docker inspect postgres --format '{{.Config.Image}}')" = "$PG_TAG" ] || { echo "n8n_postgres_image_pin=FAIL"; exit 1; }
[ "$(docker inspect moneytrack-db --format '{{.Config.Image}}')" = "$PG_TAG" ] || { echo "moneytrack_postgres_image_pin=FAIL"; exit 1; }
[ "$(docker exec n8n n8n --version 2>/dev/null | tail -n1)" = "2.22.5" ] || { echo "n8n_version_post_cutover=FAIL"; exit 1; }
[ "$(docker exec postgres postgres --version | awk '{print $3}')" = "16.14" ] || { echo "n8n_postgres_version_post_cutover=FAIL"; exit 1; }
[ "$(docker exec moneytrack-db postgres --version | awk '{print $3}')" = "16.14" ] || { echo "moneytrack_postgres_version_post_cutover=FAIL"; exit 1; }
echo "runtime_pin_gate=PASS"

# Persistence and restart invariants.
[ "$(docker inspect n8n --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}')" = "$N8N_MOUNT_BEFORE" ] || { echo "n8n_mount_post_cutover=FAIL"; exit 1; }
[ "$(docker inspect postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')" = "$PG_MOUNT_BEFORE" ] || { echo "n8n_postgres_mount_post_cutover=FAIL"; exit 1; }
[ "$(docker inspect moneytrack-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')" = "$MT_MOUNT_BEFORE" ] || { echo "moneytrack_db_mount_post_cutover=FAIL"; exit 1; }
for c in n8n postgres moneytrack-db; do
  [ "$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}')" = "unless-stopped" ] || { echo "$c restart_policy_post_cutover=FAIL"; exit 1; }
done
echo "persistence_restart_gate=PASS"

# Bounded Docker log rotation.
for c in n8n postgres moneytrack-db; do
  driver="$(docker inspect "$c" --format '{{.HostConfig.LogConfig.Type}}')"
  max_size="$(docker inspect "$c" --format '{{index .HostConfig.LogConfig.Config "max-size"}}')"
  max_file="$(docker inspect "$c" --format '{{index .HostConfig.LogConfig.Config "max-file"}}')"
  [ "$driver" = "json-file" ] || { echo "$c log_driver=FAIL actual=$driver"; exit 1; }
  [ "$max_size" = "10m" ] || { echo "$c log_max_size=FAIL actual=$max_size"; exit 1; }
  [ "$max_file" = "5" ] || { echo "$c log_max_file=FAIL actual=$max_file"; exit 1; }
  echo "$c log_rotation=PASS max_size=$max_size max_file=$max_file"
done
echo "log_rotation_gate=PASS"

# Encryption material must remain present after n8n recreation; value is never printed.
docker exec n8n node - <<'NODE'
const fs = require('fs');
const p = '/home/node/.n8n/config';
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
if (!j.encryptionKey || typeof j.encryptionKey !== 'string') process.exit(1);
NODE
echo "n8n_persistent_encryption_key_post_cutover=PASS value_not_printed=PASS"

# Final health and API transport smoke.
wait_pg postgres n8n n8n
wait_pg moneytrack-db moneytrack moneytrack
wait_n8n
BODY="$TMP/api-body.json"
HTTP="$(curl -sS --max-time 8 -o "$BODY" -w '%{http_code}' http://127.0.0.1:5678/webhook/api/v1/dashboard)"
[ "$HTTP" = "401" ] || { echo "api_missing_auth_http=FAIL actual=$HTTP body=$(cat "$BODY")"; exit 1; }
grep -Fq '"code":"INIT_DATA_MISSING"' "$BODY" || { echo "api_missing_auth_contract=FAIL body=$(cat "$BODY")"; exit 1; }
echo "api_missing_auth_contract=PASS http=401"
echo "production_health_post_cutover=PASS"

# Remove temporary rollback aliases after successful acceptance.
docker image rm "$ROLLBACK_N8N" "$ROLLBACK_PG" >/dev/null 2>&1 || true

MUTATED=0
OVERLAYS_INSTALLED=0
trap - EXIT
rm -rf "$TMP"

echo "=== PROD-H3 RUNTIME HARDENING CUTOVER PASS ==="
