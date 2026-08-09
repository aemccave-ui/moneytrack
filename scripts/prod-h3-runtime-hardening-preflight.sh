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

require() { command -v "$1" >/dev/null 2>&1 || { echo "required_command_missing=$1"; exit 1; }; }
for c in docker sha256sum grep awk sed find stat curl; do require "$c"; done
docker compose version >/dev/null 2>&1 || { echo "docker_compose_plugin=FAIL"; exit 1; }

TMP="$(mktemp -d /tmp/moneytrack-prod-h3-preflight.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

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

echo "=== PROD-H3 PREFLIGHT START ==="

for f in "$N8N_BASE" "$MT_BASE"; do
  [ -f "$f" ] || { echo "compose_base_missing=$f"; exit 1; }
done
echo "compose_base_files=PASS"

for f in "$N8N_OVERLAY" "$MT_OVERLAY"; do
  if [ -e "$f" ]; then
    if grep -Fxq "$MARKER" "$f"; then
      echo "existing_managed_overlay=PASS path=$f"
    else
      echo "existing_unmanaged_overlay=FAIL path=$f"
      exit 1
    fi
  else
    echo "managed_overlay_absent=PASS path=$f"
  fi
done

LATEST_BACKUP="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -exec test -f '{}/COMPLETE' ';' -print 2>/dev/null | sort | tail -n1)"
[ -n "$LATEST_BACKUP" ] || { echo "latest_complete_backup=FAIL"; exit 1; }
echo "latest_complete_backup=$LATEST_BACKUP"
(
  cd "$LATEST_BACKUP"
  sha256sum -c SHA256SUMS >/dev/null
)
echo "latest_backup_hashes=PASS"

for c in n8n postgres moneytrack-db; do
  docker inspect "$c" >/dev/null 2>&1 || { echo "required_container_missing=$c"; exit 1; }
  [ "$(docker inspect "$c" --format '{{.State.Running}}')" = "true" ] || { echo "required_container_not_running=$c"; exit 1; }
done

echo "critical_containers_running=PASS"

N8N_VER="$(docker exec n8n n8n --version 2>/dev/null | tail -n1)"
PG_N8N_VER="$(docker exec postgres postgres --version | awk '{print $3}')"
PG_MT_VER="$(docker exec moneytrack-db postgres --version | awk '{print $3}')"
[ "$N8N_VER" = "2.22.5" ] || { echo "n8n_runtime_drift=FAIL actual=$N8N_VER expected=2.22.5"; exit 1; }
[ "$PG_N8N_VER" = "16.14" ] || { echo "n8n_postgres_runtime_drift=FAIL actual=$PG_N8N_VER expected=16.14"; exit 1; }
[ "$PG_MT_VER" = "16.14" ] || { echo "moneytrack_postgres_runtime_drift=FAIL actual=$PG_MT_VER expected=16.14"; exit 1; }
echo "runtime_version_gate=PASS n8n=$N8N_VER postgres=$PG_N8N_VER moneytrack_db=$PG_MT_VER"

N8N_CFG="$(docker inspect n8n --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
PG_CFG="$(docker inspect postgres --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
MT_CFG="$(docker inspect moneytrack-db --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')"
[ "$N8N_CFG" = "$N8N_BASE" ] || { echo "n8n_compose_provenance_drift=FAIL actual=$N8N_CFG"; exit 1; }
[ "$PG_CFG" = "$N8N_BASE" ] || { echo "n8n_postgres_compose_provenance_drift=FAIL actual=$PG_CFG"; exit 1; }
[ "$MT_CFG" = "$MT_BASE" ] || { echo "moneytrack_db_compose_provenance_drift=FAIL actual=$MT_CFG"; exit 1; }
echo "compose_provenance_gate=PASS"

for c in n8n postgres moneytrack-db; do
  restart="$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}')"
  [ "$restart" = "unless-stopped" ] || { echo "$c restart_policy_drift=FAIL actual=$restart"; exit 1; }
  echo "$c restart_policy=$restart"
done
echo "restart_policy_gate=PASS"

N8N_MOUNT="$(docker inspect n8n --format '{{range .Mounts}}{{if eq .Destination "/home/node/.n8n"}}{{.Source}}{{end}}{{end}}')"
PG_MOUNT="$(docker inspect postgres --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"
MT_MOUNT="$(docker inspect moneytrack-db --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}')"
[ "$N8N_MOUNT" = "/var/lib/docker/volumes/n8n_n8n_data/_data" ] || { echo "n8n_mount_drift=FAIL actual=$N8N_MOUNT"; exit 1; }
[ "$PG_MOUNT" = "/var/lib/docker/volumes/n8n_postgres_data/_data" ] || { echo "n8n_postgres_mount_drift=FAIL actual=$PG_MOUNT"; exit 1; }
[ "$MT_MOUNT" = "/opt/moneytrack/postgres/data" ] || { echo "moneytrack_db_mount_drift=FAIL actual=$MT_MOUNT"; exit 1; }
echo "persistent_mount_gate=PASS"

N8N_PROJECT="$(docker inspect n8n --format '{{index .Config.Labels "com.docker.compose.project"}}')"
MT_PROJECT="$(docker inspect moneytrack-db --format '{{index .Config.Labels "com.docker.compose.project"}}')"
[ -n "$N8N_PROJECT" ] && [ -n "$MT_PROJECT" ] || { echo "compose_project_resolution=FAIL"; exit 1; }
echo "compose_projects=PASS n8n_project=$N8N_PROJECT moneytrack_project=$MT_PROJECT"

# Validate merged candidate configuration without writing production overlay files.
docker compose -p "$N8N_PROJECT" -f "$N8N_BASE" -f "$TMP/n8n-overlay.yml" config > "$TMP/n8n-rendered.yml"
docker compose -p "$MT_PROJECT" -f "$MT_BASE" -f "$TMP/mt-overlay.yml" config > "$TMP/mt-rendered.yml"
echo "candidate_compose_render=PASS"

# Minimal assertions against rendered candidates.
grep -Fq "image: $N8N_DIGEST" "$TMP/n8n-rendered.yml" || { echo "candidate_n8n_pin=FAIL"; exit 1; }
[ "$(grep -Fc "image: $PG_TAG" "$TMP/n8n-rendered.yml")" -ge 1 ] || { echo "candidate_n8n_postgres_pin=FAIL"; exit 1; }
grep -Fq "image: $PG_TAG" "$TMP/mt-rendered.yml" || { echo "candidate_moneytrack_postgres_pin=FAIL"; exit 1; }
[ "$(grep -Fc 'max-size: 10m' "$TMP/n8n-rendered.yml")" -ge 2 ] || { echo "candidate_n8n_project_log_rotation=FAIL"; exit 1; }
grep -Fq 'max-size: 10m' "$TMP/mt-rendered.yml" || { echo "candidate_moneytrack_log_rotation=FAIL"; exit 1; }
echo "candidate_pin_and_logging_gate=PASS"

if docker image inspect "$N8N_DIGEST" >/dev/null 2>&1; then
  echo "n8n_pinned_image_local=PASS"
else
  echo "n8n_pinned_image_local=ABSENT pull_required=true"
fi
if docker image inspect "$PG_TAG" >/dev/null 2>&1; then
  echo "postgres_exact_tag_local=PASS"
else
  echo "postgres_exact_tag_local=ABSENT pull_required=true"
fi

curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null
docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack >/dev/null
docker exec postgres pg_isready -U n8n -d n8n >/dev/null
echo "production_health_pre_cutover=PASS"

echo "=== PROD-H3 PREFLIGHT PASS ==="
