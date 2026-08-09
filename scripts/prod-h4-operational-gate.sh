#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/opt/moneytrack/backups}"
N8N_OVERLAY="/root/stack/n8n/docker-compose.prod-h.yml"
MT_OVERLAY="/opt/moneytrack/postgres/docker-compose.prod-h.yml"
N8N_CONTEXT="/root/stack/n8n/compose-interpolation.prod-h.sh"
MT_CONTEXT="/opt/moneytrack/postgres/compose-interpolation.prod-h.sh"
N8N_DIGEST="n8nio/n8n@sha256:a49bc161141d6c4b9c495b5a6e3c7c1932e61d2ed2fe3fdca01262064b4b23ca"
PG_TAG="postgres:16.14"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required_command_missing=$1"
    exit 1
  }
}

for c in docker curl find stat date df awk grep sed sort openssl systemctl findmnt; do
  require "$c"
done

TMP="$(mktemp -d /tmp/moneytrack-prod-h4-gate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
warn=0

pass() { echo "$1=PASS${2:+ $2}"; }
warn() { echo "$1=WARN${2:+ $2}"; warn=$((warn+1)); }
fail() { echo "$1=FAIL${2:+ $2}"; fail=$((fail+1)); }

check_tls() {
  local host="$1" cert="$TMP/${host}.cert" end epoch now days
  if ! timeout 8 openssl s_client -servername "$host" -connect "$host:443" </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate > "$cert" 2>/dev/null; then
    fail "tls_${host//./_}" "connect_or_parse_failed=true"
    return
  fi
  end="$(sed 's/^notAfter=//' "$cert")"
  epoch="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [ "$epoch" -le "$now" ]; then
    fail "tls_${host//./_}" "expired=true"
    return
  fi
  days=$(( (epoch-now) / 86400 ))
  if [ "$days" -lt 14 ]; then
    fail "tls_${host//./_}" "days_remaining=$days"
  elif [ "$days" -lt 30 ]; then
    warn "tls_${host//./_}" "days_remaining=$days"
  else
    pass "tls_${host//./_}" "days_remaining=$days"
  fi
}

echo "=== PROD-H4 OPERATIONAL GATE START ==="

printf '\n=== H4 / 1. HARDENED RUNTIME ===\n'
for c in n8n postgres moneytrack-db; do
  if ! docker inspect "$c" >/dev/null 2>&1; then
    fail "${c}_container" "present=false"
    continue
  fi
  running="$(docker inspect "$c" --format '{{.State.Running}}')"
  [ "$running" = "true" ] && pass "${c}_running" || fail "${c}_running" "actual=$running"
  restart="$(docker inspect "$c" --format '{{.HostConfig.RestartPolicy.Name}}')"
  [ "$restart" = "unless-stopped" ] && pass "${c}_restart_policy" || fail "${c}_restart_policy" "actual=$restart"
  driver="$(docker inspect "$c" --format '{{.HostConfig.LogConfig.Type}}')"
  max_size="$(docker inspect "$c" --format '{{index .HostConfig.LogConfig.Config "max-size"}}')"
  max_file="$(docker inspect "$c" --format '{{index .HostConfig.LogConfig.Config "max-file"}}')"
  if [ "$driver" = "json-file" ] && [ "$max_size" = "10m" ] && [ "$max_file" = "5" ]; then
    pass "${c}_log_rotation" "max_size=$max_size max_file=$max_file"
  else
    fail "${c}_log_rotation" "driver=$driver max_size=${max_size:-none} max_file=${max_file:-none}"
  fi
done

if [ "$(docker inspect n8n --format '{{.Config.Image}}')" = "$N8N_DIGEST" ]; then
  pass "n8n_image_pin"
else
  fail "n8n_image_pin" "actual=$(docker inspect n8n --format '{{.Config.Image}}')"
fi
for c in postgres moneytrack-db; do
  if [ "$(docker inspect "$c" --format '{{.Config.Image}}')" = "$PG_TAG" ]; then
    pass "${c}_image_pin"
  else
    fail "${c}_image_pin" "actual=$(docker inspect "$c" --format '{{.Config.Image}}')"
  fi
done

[ -f "$N8N_OVERLAY" ] && pass "n8n_hardening_overlay" || fail "n8n_hardening_overlay" "missing=true"
[ -f "$MT_OVERLAY" ] && pass "moneytrack_hardening_overlay" || fail "moneytrack_hardening_overlay" "missing=true"
for f in "$N8N_CONTEXT" "$MT_CONTEXT"; do
  if [ -f "$f" ]; then
    mode="$(stat -c '%a' "$f")"
    [ "$mode" = "600" ] && pass "compose_context_$(basename "$(dirname "$f")")" "mode=$mode" || fail "compose_context_permissions" "path=$f mode=$mode"
  else
    fail "compose_context_snapshot" "path=$f missing=true"
  fi
done

printf '\n=== H4 / 2. SERVICE / API HEALTH ===\n'
if docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack >/dev/null 2>&1; then pass "moneytrack_db_health"; else fail "moneytrack_db_health"; fi
if docker exec postgres pg_isready -U n8n -d n8n >/dev/null 2>&1; then pass "n8n_metadata_db_health"; else fail "n8n_metadata_db_health"; fi
if curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null; then pass "n8n_health"; else fail "n8n_health"; fi
body="$TMP/api.json"
http="$(curl -sS --max-time 8 -o "$body" -w '%{http_code}' http://127.0.0.1:5678/webhook/api/v1/dashboard || true)"
if [ "$http" = "401" ] && grep -Fq '"code":"INIT_DATA_MISSING"' "$body"; then
  pass "api_missing_auth_contract" "http=401"
else
  fail "api_missing_auth_contract" "http=${http:-none}"
fi

printf '\n=== H4 / 3. BACKUP / RESTORE OPERATIONS ===\n'
for unit in moneytrack-backup.timer moneytrack-restore-verify.timer; do
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [ "$enabled" = "enabled" ] && [ "$active" = "active" ]; then
    pass "${unit//./_}" "enabled=$enabled active=$active"
  else
    fail "${unit//./_}" "enabled=${enabled:-unknown} active=${active:-unknown}"
  fi
done

latest="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -exec test -f '{}/COMPLETE' ';' -print 2>/dev/null | sort | tail -n1)"
if [ -n "$latest" ]; then
  stamp="$(basename "$latest")"
  epoch="$(date -u -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age_hours=$(( (now-epoch) / 3600 ))
  if ( cd "$latest" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    pass "latest_backup_hashes" "path=$latest"
  else
    fail "latest_backup_hashes" "path=$latest"
  fi
  if [ "$age_hours" -le 36 ]; then
    pass "latest_backup_freshness" "age_hours=$age_hours"
  else
    fail "latest_backup_freshness" "age_hours=$age_hours"
  fi
else
  fail "latest_backup" "not_found=true"
fi

for svc in moneytrack-backup.service moneytrack-restore-verify.service; do
  result="$(systemctl show "$svc" -p Result --value 2>/dev/null || true)"
  state="$(systemctl show "$svc" -p ActiveState --value 2>/dev/null || true)"
  if [ "$result" = "failed" ]; then
    fail "${svc//./_}_last_result" "result=failed state=$state"
  elif [ -z "$result" ] || [ "$result" = "success" ]; then
    pass "${svc//./_}_last_result" "result=${result:-not-run-yet} state=${state:-unknown}"
  else
    warn "${svc//./_}_last_result" "result=$result state=${state:-unknown}"
  fi
done

printf '\n=== H4 / 4. DISK / TLS ===\n'
root_used="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [ "$root_used" -ge 90 ]; then fail "root_disk_usage" "percent=$root_used"; elif [ "$root_used" -ge 80 ]; then warn "root_disk_usage" "percent=$root_used"; else pass "root_disk_usage" "percent=$root_used"; fi
backup_used="$(df -P "$BACKUP_ROOT" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [ "$backup_used" -ge 90 ]; then fail "backup_disk_usage" "percent=$backup_used"; elif [ "$backup_used" -ge 80 ]; then warn "backup_disk_usage" "percent=$backup_used"; else pass "backup_disk_usage" "percent=$backup_used"; fi

certbot_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
certbot_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
if [ "$certbot_enabled" = "enabled" ] && [ "$certbot_active" = "active" ]; then pass "certbot_timer"; else fail "certbot_timer" "enabled=$certbot_enabled active=$certbot_active"; fi
check_tls n8n.moneytrackapp.xyz
check_tls app.moneytrackapp.xyz

printf '\n=== H4 / 5. ALERTING VISIBILITY ===\n'
failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | grep -Ei 'moneytrack|n8n|postgres|certbot' || true)"
if [ -z "$failed_units" ]; then pass "critical_failed_units" "count=0"; else warn "critical_failed_units" "present=true"; printf '%s\n' "$failed_units" | sed 's/^/  /'; fi

onfailure_files="$(grep -RIlE '^[[:space:]]*OnFailure=' /etc/systemd/system 2>/dev/null | grep -Ei 'moneytrack|n8n|postgres|certbot' || true)"
monitor_units="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'moneytrack.*(alert|monitor|health)|((alert|monitor|health).*moneytrack)' || true)"
if [ -n "$onfailure_files" ] || [ -n "$monitor_units" ]; then
  pass "operator_alerting_hook" "evidence_present=true"
  [ -n "$onfailure_files" ] && printf '%s\n' "$onfailure_files" | sed 's/^/  onfailure_file=/'
  [ -n "$monitor_units" ] && printf '%s\n' "$monitor_units" | sed 's/^/  monitor_unit=/'
else
  warn "operator_alerting_hook" "evidence_present=false"
fi

printf '\n=== H4 / 6. OFF-HOST BACKUP EVIDENCE ===\n'
remote_mounts="$(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null | grep -Ei ' (nfs|nfs4|cifs|sshfs|fuse\.rclone|s3fs|davfs|fuse\.sshfs)( |$)' || true)"
offhost_units="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'moneytrack.*(offsite|offhost|remote|sync|upload)|((offsite|offhost|remote|sync|upload).*moneytrack)' || true)"
tools=()
for t in rclone restic aws az gcloud borg rsync; do command -v "$t" >/dev/null 2>&1 && tools+=("$t"); done

if [ -n "$remote_mounts" ] || [ -n "$offhost_units" ]; then
  pass "off_host_backup_path" "evidence_present=true"
  [ -n "$remote_mounts" ] && printf '%s\n' "$remote_mounts" | sed 's/^/  remote_mount=/'
  [ -n "$offhost_units" ] && printf '%s\n' "$offhost_units" | sed 's/^/  offhost_unit=/'
else
  warn "off_host_backup_path" "evidence_present=false installed_tools=${tools[*]:-none}"
fi

backup_dev="$(findmnt -n -o SOURCE --target "$BACKUP_ROOT" 2>/dev/null || true)"
root_dev="$(findmnt -n -o SOURCE --target / 2>/dev/null || true)"
if [ -n "$backup_dev" ] && [ "$backup_dev" = "$root_dev" ]; then
  warn "backup_failure_domain" "same_device_as_root=true source=$backup_dev"
else
  pass "backup_failure_domain" "backup_source=${backup_dev:-unknown} root_source=${root_dev:-unknown}"
fi

printf '\n=== H4 / 7. OPERATIONAL SOURCE / DRIFT ===\n'
if [ -d /home/adm_mt/moneytrack-automation/.git ]; then
  drift="$(git -C /home/adm_mt/moneytrack-automation status --short 2>/dev/null || true)"
  if [ -n "$drift" ]; then
    warn "automation_checkout_drift" "present=true"
    printf '%s\n' "$drift" | sed 's/^/  /'
  else
    pass "automation_checkout_drift" "present=false"
  fi
else
  warn "automation_checkout_git" "present=false"
fi

printf '\n=== H4 / 8. SUMMARY ===\n'
echo "operational_failures=$fail"
echo "operational_warnings=$warn"
if [ "$fail" -eq 0 ]; then
  echo "PROD-H4 operational_gate=PASS_WITH_DEBT_REVIEW"
else
  echo "PROD-H4 operational_gate=FAIL"
  exit 1
fi

echo "=== PROD-H4 OPERATIONAL GATE COMPLETE ==="
