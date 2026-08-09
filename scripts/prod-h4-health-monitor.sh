#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/opt/moneytrack/backups}"
TMP="$(mktemp -d /tmp/moneytrack-prod-h4-monitor.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for c in docker curl find date df awk grep openssl systemctl timeout sha256sum mktemp sed; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "required_command_missing=$c"
    exit 1
  }
done

failures=0
warnings=0

pass() { echo "$1=PASS${2:+ $2}"; }
warn() { echo "$1=WARN${2:+ $2}"; warnings=$((warnings+1)); }
fail() { echo "$1=FAIL${2:+ $2}"; failures=$((failures+1)); }

check_tls() {
  local host cert end epoch now days
  host="$1"
  cert="$TMP/${host}.cert"

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

echo "=== MONEYTRACK OPERATIONAL HEALTH MONITOR START ==="

if docker exec moneytrack-db pg_isready -U moneytrack -d moneytrack >/dev/null 2>&1; then pass moneytrack_db_health; else fail moneytrack_db_health; fi
if docker exec postgres pg_isready -U n8n -d n8n >/dev/null 2>&1; then pass n8n_metadata_db_health; else fail n8n_metadata_db_health; fi
if curl -fsS --max-time 5 http://127.0.0.1:5678/healthz >/dev/null 2>&1; then pass n8n_health; else fail n8n_health; fi

body="$TMP/api.json"
http="$(curl -sS --max-time 8 -o "$body" -w '%{http_code}' http://127.0.0.1:5678/webhook/api/v1/dashboard || true)"
if [ "$http" = "401" ] && grep -Fq '"code":"INIT_DATA_MISSING"' "$body"; then
  pass api_missing_auth_contract "http=401"
else
  fail api_missing_auth_contract "http=${http:-none}"
fi

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
if [ -z "$latest" ]; then
  fail latest_backup "not_found=true"
else
  stamp="$(basename "$latest")"
  epoch="$(date -u -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age_hours=$(( (now-epoch) / 3600 ))

  if ( cd "$latest" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    pass latest_backup_hashes
  else
    fail latest_backup_hashes
  fi

  if [ "$age_hours" -le 36 ]; then
    pass latest_backup_freshness "age_hours=$age_hours"
  else
    fail latest_backup_freshness "age_hours=$age_hours"
  fi
fi

root_used="$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [ "$root_used" -ge 90 ]; then
  fail root_disk_usage "percent=$root_used"
elif [ "$root_used" -ge 80 ]; then
  warn root_disk_usage "percent=$root_used"
else
  pass root_disk_usage "percent=$root_used"
fi

certbot_enabled="$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
certbot_active="$(systemctl is-active certbot.timer 2>/dev/null || true)"
if [ "$certbot_enabled" = "enabled" ] && [ "$certbot_active" = "active" ]; then
  pass certbot_timer
else
  fail certbot_timer "enabled=${certbot_enabled:-unknown} active=${certbot_active:-unknown}"
fi

check_tls n8n.moneytrackapp.xyz
check_tls app.moneytrackapp.xyz

echo "health_monitor_failures=$failures"
echo "health_monitor_warnings=$warnings"
if [ "$failures" -ne 0 ]; then
  echo "MONEYTRACK operational_health=FAIL"
  exit 1
fi

echo "MONEYTRACK operational_health=PASS"
echo "=== MONEYTRACK OPERATIONAL HEALTH MONITOR COMPLETE ==="
