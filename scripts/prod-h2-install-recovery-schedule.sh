#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "root_required=FAIL"; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB_DIR="/usr/local/lib/moneytrack"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/moneytrack/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

for f in \
  prod-h2-backup-now.sh \
  prod-h2-restore-verify.sh \
  prod-h2-retention.sh; do
  src="$REPO_ROOT/scripts/$f"
  [ -f "$src" ] || { echo "required_script_missing=$src"; exit 1; }
  bash -n "$src"
done

echo "=== PROD-H2 RECOVERY SCHEDULE INSTALL START ==="
echo "backup_root=$BACKUP_ROOT retention_days=$RETENTION_DAYS"

install -d -m 0755 "$LIB_DIR"
install -m 0755 "$REPO_ROOT/scripts/prod-h2-backup-now.sh" "$LIB_DIR/prod-h2-backup-now.sh"
install -m 0755 "$REPO_ROOT/scripts/prod-h2-restore-verify.sh" "$LIB_DIR/prod-h2-restore-verify.sh"
install -m 0755 "$REPO_ROOT/scripts/prod-h2-retention.sh" "$LIB_DIR/prod-h2-retention.sh"

echo "recovery_scripts_installed=PASS dir=$LIB_DIR"

cat > /etc/systemd/system/moneytrack-backup.service <<EOF
[Unit]
Description=MoneyTrack protected production backup
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
Environment=BACKUP_ROOT=$BACKUP_ROOT
Environment=RETENTION_DAYS=$RETENTION_DAYS
ExecStart=$LIB_DIR/prod-h2-backup-now.sh
ExecStartPost=$LIB_DIR/prod-h2-retention.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UMask=0077
EOF

cat > /etc/systemd/system/moneytrack-backup.timer <<'EOF'
[Unit]
Description=Daily MoneyTrack protected production backup

[Timer]
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=10m
Persistent=true
Unit=moneytrack-backup.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/moneytrack-restore-verify.service <<EOF
[Unit]
Description=MoneyTrack isolated restore verification
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
Environment=BACKUP_ROOT=$BACKUP_ROOT
ExecStart=$LIB_DIR/prod-h2-restore-verify.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UMask=0077
EOF

cat > /etc/systemd/system/moneytrack-restore-verify.timer <<'EOF'
[Unit]
Description=Weekly MoneyTrack isolated restore verification

[Timer]
OnCalendar=Sun *-*-* 05:15:00
RandomizedDelaySec=10m
Persistent=true
Unit=moneytrack-restore-verify.service

[Install]
WantedBy=timers.target
EOF

chmod 0644 \
  /etc/systemd/system/moneytrack-backup.service \
  /etc/systemd/system/moneytrack-backup.timer \
  /etc/systemd/system/moneytrack-restore-verify.service \
  /etc/systemd/system/moneytrack-restore-verify.timer

systemd-analyze verify \
  /etc/systemd/system/moneytrack-backup.service \
  /etc/systemd/system/moneytrack-backup.timer \
  /etc/systemd/system/moneytrack-restore-verify.service \
  /etc/systemd/system/moneytrack-restore-verify.timer

echo "systemd_unit_validation=PASS"

systemctl daemon-reload
systemctl enable --now moneytrack-backup.timer moneytrack-restore-verify.timer

echo "timers_enabled=PASS"
systemctl is-enabled moneytrack-backup.timer
systemctl is-active moneytrack-backup.timer
systemctl is-enabled moneytrack-restore-verify.timer
systemctl is-active moneytrack-restore-verify.timer

echo "scheduled_units:"
systemctl list-timers --all --no-pager \
  | grep -E 'moneytrack-(backup|restore-verify)\.timer' || true

echo "=== PROD-H2 RECOVERY SCHEDULE INSTALL COMPLETE ==="
