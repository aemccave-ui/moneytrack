#!/usr/bin/env bash
set -euo pipefail

UNIT_RAW="${1:-unknown}"
STATE_DIR="/var/lib/moneytrack/operator-alerts"
LOG_FILE="$STATE_DIR/alerts.log"
LATEST_FILE="$STATE_DIR/latest"
MARKER_FILE="$STATE_DIR/UNACKNOWLEDGED"

for c in date hostname install sed cut logger; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "required_command_missing=$c"
    exit 1
  }
done

SAFE_UNIT="$(printf '%s' "$UNIT_RAW" | sed 's/[^A-Za-z0-9_.@:-]/_/g' | cut -c1-160)"
[ -n "$SAFE_UNIT" ] || SAFE_UNIT="unknown"

umask 027
install -d -m 0750 "$STATE_DIR"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname)"

printf '%s severity=ERROR host=%s unit=%s\n' "$TS" "$HOST" "$SAFE_UNIT" >> "$LOG_FILE"
printf '%s unit=%s\n' "$TS" "$SAFE_UNIT" > "$LATEST_FILE"
touch "$MARKER_FILE"
chmod 0640 "$LOG_FILE" "$LATEST_FILE" "$MARKER_FILE"

logger -p daemon.err -t moneytrack-alert -- "failure unit=$SAFE_UNIT host=$HOST"

echo "operator_alert_recorded=PASS unit=$SAFE_UNIT values_not_printed=PASS"
