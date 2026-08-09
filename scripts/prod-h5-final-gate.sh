#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H4_GATE="$SCRIPT_DIR/prod-h4-operational-gate.sh"
MONITOR="/usr/local/lib/moneytrack/prod-h4-health-monitor.sh"
DEBT_FILE="/etc/moneytrack/prod-h4-debt.env"
RUNBOOK="$SCRIPT_DIR/../docs/runbooks/PROD-H-operations.md"
TMP="$(mktemp -d /tmp/moneytrack-prod-h5-gate.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

for c in bash grep awk sed sort systemctl mktemp; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "required_command_missing=$c"
    exit 1
  }
done

[ -f "$H4_GATE" ] || { echo "h4_gate_missing=FAIL path=$H4_GATE"; exit 1; }
[ -x "$MONITOR" ] || { echo "installed_health_monitor=FAIL path=$MONITOR"; exit 1; }
[ -f "$DEBT_FILE" ] || { echo "controlled_debt_record=FAIL path=$DEBT_FILE"; exit 1; }
[ -f "$RUNBOOK" ] || { echo "operations_runbook=FAIL path=$RUNBOOK"; exit 1; }

echo "=== PROD-H5 FINAL PRODUCTION HARDENING GATE START ==="

H4_OUT="$TMP/h4.out"
if bash "$H4_GATE" > "$H4_OUT" 2>&1; then
  cat "$H4_OUT"
else
  cat "$H4_OUT"
  echo "h4_operational_gate_dependency=FAIL"
  exit 1
fi

grep -Fq 'operational_failures=0' "$H4_OUT" || {
  echo "h4_operational_failures=FAIL"
  exit 1
}
grep -Fq 'operator_alerting_hook=PASS' "$H4_OUT" || {
  echo "operator_alerting_hook=FAIL"
  exit 1
}
echo "h4_operational_gate_dependency=PASS"

# No warning outside the explicitly controlled MEDIUM debt set may survive H5.
unexpected=0
while IFS= read -r line; do
  key="${line%%=*}"
  case "$key" in
    off_host_backup_path|backup_failure_domain|automation_checkout_drift)
      echo "accepted_medium_warning=$key"
      ;;
    *)
      echo "unexpected_operational_warning=FAIL line=$line"
      unexpected=$((unexpected+1))
      ;;
  esac
done < <(grep '=WARN' "$H4_OUT" || true)
[ "$unexpected" -eq 0 ] || exit 1
echo "operational_warning_scope=PASS"

# Re-run the installed monitor directly; it is read-only on success.
MON_OUT="$TMP/monitor.out"
if "$MONITOR" > "$MON_OUT" 2>&1; then
  cat "$MON_OUT"
else
  cat "$MON_OUT"
  echo "installed_health_monitor_gate=FAIL"
  exit 1
fi
grep -Fq 'MONEYTRACK operational_health=PASS' "$MON_OUT" || {
  echo "installed_health_monitor_contract=FAIL"
  exit 1
}
echo "installed_health_monitor_gate=PASS"

# Timer and OnFailure hooks must be active.
enabled="$(systemctl is-enabled moneytrack-health-monitor.timer 2>/dev/null || true)"
active="$(systemctl is-active moneytrack-health-monitor.timer 2>/dev/null || true)"
[ "$enabled" = "enabled" ] && [ "$active" = "active" ] || {
  echo "health_monitor_timer=FAIL enabled=${enabled:-unknown} active=${active:-unknown}"
  exit 1
}
echo "health_monitor_timer=PASS enabled=$enabled active=$active"

for svc in moneytrack-backup.service moneytrack-restore-verify.service moneytrack-health-monitor.service; do
  onfailure="$(systemctl show "$svc" -p OnFailure --value 2>/dev/null || true)"
  if printf '%s' "$onfailure" | grep -Fq 'moneytrack-operator-alert@'; then
    echo "$svc onfailure_hook=PASS"
  else
    echo "$svc onfailure_hook=FAIL actual=${onfailure:-none}"
    exit 1
  fi
done

[ -d /var/lib/moneytrack/operator-alerts ] || {
  echo "durable_alert_state=FAIL"
  exit 1
}
echo "durable_alert_state=PASS"

# Controlled residual risks are explicit and non-secret.
grep -Fxq 'OFFHOST_BACKUP_STATUS=ACCEPTED_MEDIUM_EXTERNAL_DEPENDENCY' "$DEBT_FILE" || {
  echo "offhost_debt_decision=FAIL"
  exit 1
}
grep -Fxq 'EXTERNAL_PUSH_ALERTING_STATUS=ACCEPTED_MEDIUM_EXTERNAL_DEPENDENCY' "$DEBT_FILE" || {
  echo "external_push_alerting_debt_decision=FAIL"
  exit 1
}
grep -Fxq 'AUTOMATION_CHECKOUT_DRIFT_STATUS=ACCEPTED_MEDIUM_OPERATIONAL_DEBT' "$DEBT_FILE" || {
  echo "automation_drift_debt_decision=FAIL"
  exit 1
}
echo "controlled_medium_debt_gate=PASS"

# Runbook must retain the safety boundary and recovery commands.
grep -Fq 'Never use `docker compose down -v`' "$RUNBOOK" || { echo "runbook_volume_safety=FAIL"; exit 1; }
grep -Fq '/usr/local/lib/moneytrack/prod-h2-backup-now.sh' "$RUNBOOK" || { echo "runbook_backup_command=FAIL"; exit 1; }
grep -Fq '/usr/local/lib/moneytrack/prod-h2-restore-verify.sh' "$RUNBOOK" || { echo "runbook_restore_command=FAIL"; exit 1; }
echo "operations_runbook_gate=PASS"

echo "blocker_debt=0"
echo "high_debt=0"
echo "accepted_medium_debt=offhost_backup,external_push_alerting,automation_checkout_drift"
echo "PROD-H5 final_gate=PASS"
echo "PROD-H=COMPLETE"
echo "=== PROD-H5 FINAL PRODUCTION HARDENING GATE COMPLETE ==="
