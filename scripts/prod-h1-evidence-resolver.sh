#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

section() { printf '\n=== %s ===\n' "$*"; }

containers=(n8n postgres moneytrack-db)

echo "PROD-H1.1 evidence_resolver=START"
echo "git_head=$(git rev-parse HEAD)"

section "PROD-H1.1 / 1. N8N PERSISTENT ENCRYPTION KEY SIGNAL"
if ! docker inspect n8n >/dev/null 2>&1; then
  echo "n8n_container_present=FAIL"
else
  if docker exec n8n sh -lc 'test -f /home/node/.n8n/config'; then
    echo "n8n_persistent_config_present=PASS"
    docker exec n8n sh -lc 'stat -c "n8n_persistent_config mode=%a owner=%U:%G path=%n" /home/node/.n8n/config' 2>/dev/null || true
    if docker exec n8n sh -lc "grep -Eq '\"encryptionKey\"[[:space:]]*:' /home/node/.n8n/config"; then
      echo "n8n_persistent_encryption_key_present=PASS value_not_printed=PASS"
    else
      echo "n8n_persistent_encryption_key_present=FAIL"
    fi
  else
    echo "n8n_persistent_config_present=FAIL"
  fi

  if docker exec n8n sh -lc 'test -n "${N8N_ENCRYPTION_KEY:-}"'; then
    echo "n8n_env_encryption_key_present=PASS value_not_printed=PASS"
  else
    echo "n8n_env_encryption_key_present=ABSENT"
  fi
fi

section "PROD-H1.1 / 2. CONTAINER DEPLOYMENT PROVENANCE"
for c in "${containers[@]}"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    echo "$c present=FAIL"
    continue
  fi

  project="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
  service="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || true)"
  working_dir="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || true)"
  config_files="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)"
  oneoff="$(docker inspect "$c" --format '{{index .Config.Labels "com.docker.compose.oneoff"}}' 2>/dev/null || true)"

  echo "$c compose_project=${project:-ABSENT} compose_service=${service:-ABSENT} compose_oneoff=${oneoff:-ABSENT}"
  echo "$c compose_working_dir=${working_dir:-ABSENT}"
  echo "$c compose_config_files=${config_files:-ABSENT}"

  if [ -n "$config_files" ]; then
    IFS=',' read -ra paths <<< "$config_files"
    for p in "${paths[@]}"; do
      p="$(printf '%s' "$p" | xargs)"
      if [ -n "$p" ] && [ -e "$p" ]; then
        stat -c "$c compose_file_present=PASS mode=%a owner=%U:%G path=%n" "$p" 2>/dev/null || true
      elif [ -n "$p" ]; then
        echo "$c compose_file_present=FAIL path=$p"
      fi
    done
  fi
done

section "PROD-H1.1 / 3. EXACT IMAGE ID / DIGEST SIGNAL"
for c in "${containers[@]}"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    continue
  fi
  image_ref="$(docker inspect "$c" --format '{{.Config.Image}}')"
  image_id="$(docker inspect "$c" --format '{{.Image}}')"
  echo "$c image_ref=$image_ref"
  echo "$c image_id=$image_id"
  repo_digests="$(docker image inspect "$image_id" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null | sed '/^$/d' | paste -sd ',' - || true)"
  echo "$c repo_digests=${repo_digests:-ABSENT}"
done

if docker inspect n8n >/dev/null 2>&1; then
  n8n_version="$(docker exec n8n n8n --version 2>/dev/null | tail -n1 || true)"
  echo "n8n_runtime_version=${n8n_version:-UNKNOWN}"
fi
for c in postgres moneytrack-db; do
  if docker inspect "$c" >/dev/null 2>&1; then
    pgver="$(docker exec "$c" postgres --version 2>/dev/null | head -n1 || true)"
    echo "$c runtime_version=${pgver:-UNKNOWN}"
  fi
done

section "PROD-H1.1 / 4. DOCKER LOG ROTATION"
if docker info --format '{{.LoggingDriver}}' >/dev/null 2>&1; then
  echo "docker_default_logging_driver=$(docker info --format '{{.LoggingDriver}}')"
fi
for c in "${containers[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    driver="$(docker inspect "$c" --format '{{.HostConfig.LogConfig.Type}}')"
    opts="$(docker inspect "$c" --format '{{json .HostConfig.LogConfig.Config}}')"
    echo "$c log_driver=${driver:-default} log_options=$opts"
  fi
done

section "PROD-H1.1 / 5. CERTBOT RENEWAL SIGNAL"
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files --no-pager 2>/dev/null | grep -q '^certbot.timer'; then
    echo "certbot_timer_installed=PASS"
    systemctl is-enabled certbot.timer 2>/dev/null | sed 's/^/certbot_timer_enabled=/' || true
    systemctl is-active certbot.timer 2>/dev/null | sed 's/^/certbot_timer_active=/' || true
    systemctl list-timers certbot.timer --all --no-pager 2>/dev/null || true
  else
    echo "certbot_timer_installed=ABSENT"
  fi
else
  echo "systemctl=UNAVAILABLE"
fi

section "PROD-H1.1 / 6. MONEYTRACK BACKUP / RECOVERY ASSET SEARCH"
echo "systemd_unit_filenames:"
find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -maxdepth 2 -type f \
  \( -iname '*moneytrack*backup*' -o -iname '*moneytrack*restore*' -o -iname '*moneytrack*postgres*' -o -iname '*n8n*backup*' -o -iname '*n8n*restore*' \) \
  -printf '  %p\n' 2>/dev/null | sort -u || true

echo "backup_artifact_candidates:"
for root in /opt/moneytrack /var/backups /srv /mnt /home/adm_mt; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth 6 -type f \
    \( -iname '*.dump' -o -iname '*.backup' -o -iname '*.sql.gz' -o -iname '*moneytrack*backup*' -o -iname '*moneytrack*dump*' -o -iname '*n8n*backup*' \) \
    -printf '%TY-%Tm-%Td %TH:%TM size=%s %p\n' 2>/dev/null || true
done | sort -r | head -n 100

echo "backup_named_directories:"
for root in /opt/moneytrack /var/backups /srv /mnt /home/adm_mt; do
  [ -d "$root" ] || continue
  find "$root" -maxdepth 5 -type d \
    \( -iname '*backup*' -o -iname '*restore*' \) \
    -printf '  %p\n' 2>/dev/null || true
done | sort -u | head -n 100

section "PROD-H1.1 / 7. AUTOMATION REPOSITORY DRIFT — FILENAMES ONLY"
AUTO=/home/adm_mt/moneytrack-automation
if [ -d "$AUTO/.git" ]; then
  echo "automation_repo_head=$(git -C "$AUTO" rev-parse HEAD)"
  echo "automation_repo_branch=$(git -C "$AUTO" branch --show-current 2>/dev/null || true)"
  echo "automation_repo_status:"
  git -C "$AUTO" status --short
  echo "automation_repo_tracked_deployment_candidates:"
  git -C "$AUTO" ls-files \
    | grep -Ei '(^|/)(docker-compose|compose|Dockerfile|release|deploy|backup|restore|systemd|service|timer|config)' \
    | sed 's/^/  /' || true
else
  echo "automation_repo_git=ABSENT"
fi

section "PROD-H1.1 / 8. HEALTH REASSERTION"
if curl -fsS --max-time 5 http://127.0.0.1:5678/healthz; then
  echo
  echo "n8n_health=PASS"
else
  echo "n8n_health=FAIL"
fi
for spec in 'moneytrack-db moneytrack moneytrack' 'postgres n8n n8n'; do
  set -- $spec
  c="$1" u="$2" db="$3"
  if docker exec "$c" pg_isready -U "$u" -d "$db" >/dev/null; then
    echo "$c db_readiness=PASS"
  else
    echo "$c db_readiness=FAIL"
  fi
done

section "PROD-H1.1 / 9. COMPLETE"
echo "PROD-H1.1 evidence_resolver=COMPLETE"
