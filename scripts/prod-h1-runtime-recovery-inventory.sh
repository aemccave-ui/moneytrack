#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

say() { printf '%s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

required_cmds=(docker stat df find grep awk sed openssl curl)
for cmd in "${required_cmds[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "required_command_missing=$cmd"
    exit 1
  }
done

echo "PROD-H1 read_only_inventory=START"
echo "repo=$(pwd)"
echo "git_head=$(git rev-parse HEAD)"

section "PROD-H1 / 1. HOST"
uname -a
if [ -r /etc/os-release ]; then
  grep -E '^(NAME|VERSION|VERSION_ID|PRETTY_NAME)=' /etc/os-release || true
fi
printf 'uptime='; uptime -p || true
printf 'load='; uptime | sed 's/^.*load average: //' || true

section "PROD-H1 / 2. FILESYSTEM CAPACITY"
df -hT /
df -hT /var/lib/docker 2>/dev/null || true
df -hT /home 2>/dev/null || true

echo
say "docker_system_df:"
docker system df || true

section "PROD-H1 / 3. PRODUCTION CONTAINER INVENTORY"
containers=(n8n postgres moneytrack-db)
for c in "${containers[@]}"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    echo "$c present=FAIL"
    continue
  fi

  docker inspect "$c" --format \
    'container={{.Name}} image={{.Config.Image}} status={{.State.Status}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restart={{.HostConfig.RestartPolicy.Name}} started={{.State.StartedAt}}'

  echo "$c mounts:"
  docker inspect "$c" --format '{{range .Mounts}}  type={{.Type}} source={{.Source}} destination={{.Destination}} rw={{.RW}}{{println}}{{end}}' || true

  log_path="$(docker inspect "$c" --format '{{.LogPath}}' 2>/dev/null || true)"
  if [ -n "$log_path" ] && [ -e "$log_path" ]; then
    bytes="$(stat -c '%s' "$log_path" 2>/dev/null || echo 0)"
    echo "$c docker_log_bytes=$bytes path=$log_path"
  else
    echo "$c docker_log_bytes=UNKNOWN"
  fi

done

section "PROD-H1 / 4. IMAGE PINNING SIGNAL"
for c in "${containers[@]}"; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    continue
  fi
  image="$(docker inspect "$c" --format '{{.Config.Image}}')"
  if printf '%s' "$image" | grep -Eq ':(latest|stable)$|^[^:@]+$'; then
    echo "$c image=$image pinning=DEBT_MUTABLE_OR_UNTAGGED"
  else
    echo "$c image=$image pinning=PINNED_OR_VERSIONED"
  fi
done

section "PROD-H1 / 5. DATABASE READINESS / SIZE"
if docker inspect moneytrack-db >/dev/null 2>&1; then
  if docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack; then
    echo "moneytrack_db_readiness=PASS"
  else
    echo "moneytrack_db_readiness=FAIL"
  fi
  docker exec moneytrack-db psql -U moneytrack -d moneytrack -Atc \
    "select 'moneytrack_db_size=' || pg_size_pretty(pg_database_size(current_database()));" || true
fi

if docker inspect postgres >/dev/null 2>&1; then
  if docker exec postgres pg_isready -U n8n -d n8n; then
    echo "n8n_metadata_db_readiness=PASS"
  else
    echo "n8n_metadata_db_readiness=FAIL"
  fi
  docker exec postgres psql -U n8n -d n8n -Atc \
    "select 'n8n_metadata_db_size=' || pg_size_pretty(pg_database_size(current_database()));" || true
fi

section "PROD-H1 / 6. N8N HEALTH / VERSION"
if curl -fsS --max-time 5 http://127.0.0.1:5678/healthz; then
  echo
  echo "n8n_health=PASS"
else
  echo "n8n_health=FAIL"
fi

if docker inspect n8n >/dev/null 2>&1; then
  n8n_version="$(docker exec n8n n8n --version 2>/dev/null | tail -n1 || true)"
  echo "n8n_runtime_version=${n8n_version:-UNKNOWN}"
fi

section "PROD-H1 / 7. REQUIRED SECRET PRESENCE — VALUES NOT PRINTED"
if docker inspect n8n >/dev/null 2>&1; then
  for key in MONEYTRACK_BOT_TOKEN N8N_ENCRYPTION_KEY; do
    if docker exec n8n sh -lc "test -n \"\${$key:-}\""; then
      echo "$key presence=PASS value_not_printed=PASS"
    else
      echo "$key presence=FAIL"
    fi
  done
fi

N8N_ENV="/home/adm_mt/moneytrack-automation/config/n8n.env"
if [ -e "$N8N_ENV" ]; then
  mode="$(stat -c '%a' "$N8N_ENV")"
  owner="$(stat -c '%U:%G' "$N8N_ENV")"
  echo "n8n_env present=PASS mode=$mode owner=$owner path=$N8N_ENV"
  case "$mode" in
    600|640|400|440) echo "n8n_env_permissions=PASS_OR_RESTRICTED" ;;
    *) echo "n8n_env_permissions=REVIEW" ;;
  esac
else
  echo "n8n_env present=FAIL path=$N8N_ENV"
fi

section "PROD-H1 / 8. DEPLOYMENT SOURCE-OF-TRUTH SIGNAL"
for root in /home/adm_mt/moneytrack-automation /home/adm_mt/moneytrack; do
  if [ ! -d "$root" ]; then
    continue
  fi
  echo "deployment_root=$root"
  find "$root" -maxdepth 3 -type f \
    \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' -o -name 'Dockerfile' -o -name '*.service' \) \
    -printf '  %p\n' 2>/dev/null | sort || true
done

section "PROD-H1 / 9. BACKUP JOB / ARTIFACT EVIDENCE"
echo "systemd_timers_matching_backup_moneytrack_n8n:"
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-timers --all --no-pager 2>/dev/null \
    | grep -Ei 'backup|moneytrack|n8n|postgres' || echo "  none_found"
else
  echo "  systemctl_unavailable"
fi

echo "root_cron_matching_backup_moneytrack_n8n:"
if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null \
    | grep -Ei 'backup|moneytrack|n8n|pg_dump|postgres' || echo "  none_found_or_no_root_crontab"
else
  echo "  crontab_unavailable"
fi

echo "backup_artifacts_under_adm_mt:"
find /home/adm_mt -maxdepth 5 -type f \
  \( -iname '*.dump' -o -iname '*.backup' -o -iname '*.sql.gz' -o -iname '*backup*.tar*' -o -iname '*backup*.gz' \) \
  -printf '%TY-%Tm-%Td %TH:%TM size=%s %p\n' 2>/dev/null \
  | sort -r | head -n 30 || true

section "PROD-H1 / 10. NGINX MONEYTRACK ROUTING SIGNAL"
if command -v nginx >/dev/null 2>&1; then
  nginx -T 2>/dev/null \
    | grep -E 'server_name|listen .*443|listen .*80|proxy_pass|ssl_certificate(_key)?' \
    | sed -E 's#(ssl_certificate_key)[[:space:]]+[^;]+;#\1 <redacted-path>;#' \
    | grep -Ei 'moneytrack|n8n|app\.|server_name|listen|proxy_pass|ssl_certificate' \
    | head -n 200 || true
else
  echo "nginx_binary=NOT_FOUND"
fi

section "PROD-H1 / 11. TLS CERTIFICATE EXPIRY"
check_tls() {
  local host="$1" tmp
  tmp="$(mktemp)"
  if timeout 8 openssl s_client -servername "$host" -connect "$host:443" </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates > "$tmp" 2>/dev/null; then
    echo "tls_host=$host PASS"
    sed 's/^/  /' "$tmp"
  else
    echo "tls_host=$host FAIL"
  fi
  rm -f "$tmp"
}
check_tls n8n.moneytrackapp.xyz
check_tls app.moneytrackapp.xyz

section "PROD-H1 / 12. PORT / FIREWALL SIGNAL"
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null | grep -E ':(22|80|443|5432|5678)\b' || true
fi
if command -v ufw >/dev/null 2>&1; then
  ufw status 2>/dev/null || true
else
  echo "ufw=NOT_INSTALLED"
fi

section "PROD-H1 / 13. OPERATIONAL SIGNAL SUMMARY"
for c in "${containers[@]}"; do
  if docker inspect "$c" >/dev/null 2>&1; then
    running="$(docker inspect "$c" --format '{{.State.Running}}')"
    restart="$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}')"
    echo "$c running=$running restart_policy=${restart:-none}"
  else
    echo "$c present=false"
  fi
done

echo
if [ -d /home/adm_mt/moneytrack-automation/.git ]; then
  echo "automation_repo_git=PASS"
  git -C /home/adm_mt/moneytrack-automation status --short || true
  echo "automation_repo_head=$(git -C /home/adm_mt/moneytrack-automation rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
else
  echo "automation_repo_git=ABSENT_OR_NOT_GIT"
fi

section "PROD-H1 / 14. INVENTORY COMPLETE"
echo "PROD-H1 read_only_inventory=COMPLETE"
echo "NOTE: absence of visible backup artifacts/jobs is evidence of an unproven backup path, not proof that no external backup exists."
