#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/moneytrack"
STATE_DIR="/var/lib/moneytrack/operator-alerts"
DEBT_DIR="/etc/moneytrack"
DEBT_FILE="$DEBT_DIR/prod-h4-debt.env"

if [ "$(id -u)" -ne 0 ]; then
  echo "root_required=FAIL"
  exit 1
fi

for c in install systemctl grep id; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "required_command_missing=$c"
    exit 1
  }
done

for f in prod-h4-operator-alert.sh prod-h4-health-monitor.sh; do
  [ -f "$SCRIPT_DIR/$f" ] || {
    echo "required_script_missing=$SCRIPT_DIR/$f"
    exit 1
  }
done

echo "=== PROD-H4 OPERATOR MONITORING INSTALL START ==="

install -d -m 0750 "$LIB_DIR" "$STATE_DIR"
install -d -m 0755 "$DEBT_DIR"
install -m 0750 "$SCRIPT_DIR/prod-h4-operator-alert.sh" "$LIB_DIR/prod-h4-operator-alert.sh"
install -m 0750 "$SCRIPT_DIR/prod-h4-health-monitor.sh" "$LIB_DIR/prod-h4-health-monitor.sh"
echo "monitoring_scripts_installed=PASS"

cat > /etc/systemd/system/moneytrack-operator-alert@.service <<'UNIT'
[Unit]
Description=MoneyTrack durable operator alert for %i

[Service]
Type=oneshot
ExecStart=/usr/local/lib/moneytrack/prod-h4-operator-alert.sh %i
UNIT

cat > /etc/systemd/system/moneytrack-health-monitor.service <<'UNIT'
[Unit]
Description=MoneyTrack production health monitor
After=docker.service network-online.target
Wants=network-online.target
OnFailure=moneytrack-operator-alert@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/moneytrack/prod-h4-health-monitor.sh
UNIT

cat > /etc/systemd/system/moneytrack-health-monitor.timer <<'UNIT'
[Unit]
Description=Run MoneyTrack production health monitor periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
AccuracySec=1min
Unit=moneytrack-health-monitor.service

[Install]
WantedBy=timers.target
UNIT

install -d -m 0755 \
  /etc/systemd/system/moneytrack-backup.service.d \
  /etc/systemd/system/moneytrack-restore-verify.service.d

cat > /etc/systemd/system/moneytrack-backup.service.d/prod-h4-alert.conf <<'UNIT'
[Unit]
OnFailure=moneytrack-operator-alert@%n.service
UNIT

cat > /etc/systemd/system/moneytrack-restore-verify.service.d/prod-h4-alert.conf <<'UNIT'
[Unit]
OnFailure=moneytrack-operator-alert@%n.service
UNIT

cat > "$DEBT_FILE" <<'EOF'
# PROD-H4 controlled residual debt. Non-secret operational decision record.
OFFHOST_BACKUP_STATUS=ACCEPTED_MEDIUM_EXTERNAL_DEPENDENCY
EXTERNAL_PUSH_ALERTING_STATUS=ACCEPTED_MEDIUM_EXTERNAL_DEPENDENCY
AUTOMATION_CHECKOUT_DRIFT_STATUS=ACCEPTED_MEDIUM_OPERATIONAL_DEBT
EOF
chmod 0644 "$DEBT_FILE"
echo "controlled_debt_record=PASS path=$DEBT_FILE"

systemctl daemon-reload
systemctl enable --now moneytrack-health-monitor.timer >/dev/null

echo "health_monitor_timer_enable=PASS"

# Run the monitor once immediately. It is read-only; failure will exercise OnFailure naturally.
if systemctl start moneytrack-health-monitor.service; then
  echo "health_monitor_initial_run=PASS"
else
  echo "health_monitor_initial_run=FAIL"
  systemctl status moneytrack-health-monitor.service --no-pager || true
  exit 1
fi

for svc in moneytrack-backup.service moneytrack-restore-verify.service moneytrack-health-monitor.service; do
  onfailure="$(systemctl show "$svc" -p OnFailure --value 2>/dev/null || true)"
  if printf '%s' "$onfailure" | grep -Fq 'moneytrack-operator-alert@'; then
    echo "$svc onfailure_hook=PASS"
  else
    echo "$svc onfailure_hook=FAIL actual=${onfailure:-none}"
    exit 1
  fi
done

enabled="$(systemctl is-enabled moneytrack-health-monitor.timer 2>/dev/null || true)"
active="$(systemctl is-active moneytrack-health-monitor.timer 2>/dev/null || true)"
if [ "$enabled" = "enabled" ] && [ "$active" = "active" ]; then
  echo "health_monitor_timer=PASS enabled=$enabled active=$active"
else
  echo "health_monitor_timer=FAIL enabled=${enabled:-unknown} active=${active:-unknown}"
  exit 1
fi

echo "local_operator_alerting=PASS durable_state=$STATE_DIR external_recipient_not_assumed=PASS"
echo "=== PROD-H4 OPERATOR MONITORING INSTALL COMPLETE ==="
