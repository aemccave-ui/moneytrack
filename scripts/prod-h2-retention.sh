#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/opt/moneytrack/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

case "$RETENTION_DAYS" in
  ''|*[!0-9]*) echo "retention_days_invalid=$RETENTION_DAYS"; exit 1 ;;
esac
[ "$RETENTION_DAYS" -ge 2 ] || { echo "retention_days_too_small=$RETENTION_DAYS"; exit 1; }

mkdir -p "$BACKUP_ROOT"
ROOT_REAL="$(readlink -f "$BACKUP_ROOT")"
case "$ROOT_REAL" in
  /opt/moneytrack/backups|/opt/moneytrack/backups/*) ;;
  *) echo "backup_root_safety_gate=FAIL resolved=$ROOT_REAL"; exit 1 ;;
esac

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=== PROD-H2 RETENTION START ==="
echo "backup_root=$ROOT_REAL retention_days=$RETENTION_DAYS now_utc=$now"

deleted=0
kept=0
skipped=0

while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  base="$(basename "$dir")"

  if ! printf '%s' "$base" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$'; then
    echo "skip_noncanonical_dir=$dir"
    skipped=$((skipped + 1))
    continue
  fi

  if [ ! -f "$dir/COMPLETE" ]; then
    echo "skip_incomplete_backup=$dir"
    skipped=$((skipped + 1))
    continue
  fi

  required_ok=true
  for f in moneytrack.dump n8n-metadata.dump n8n-data.tar.gz manifest.txt SHA256SUMS; do
    if [ ! -s "$dir/$f" ]; then
      required_ok=false
      break
    fi
  done
  if [ "$required_ok" != true ]; then
    echo "skip_malformed_backup=$dir"
    skipped=$((skipped + 1))
    continue
  fi

  if find "$dir" -maxdepth 0 -type d -mtime "+$((RETENTION_DAYS - 1))" | grep -q .; then
    echo "delete_expired_complete_backup=$dir"
    rm -rf -- "$dir"
    deleted=$((deleted + 1))
  else
    kept=$((kept + 1))
  fi
done < <(find "$ROOT_REAL" -mindepth 1 -maxdepth 1 -type d -print | sort)

echo "retention_deleted=$deleted"
echo "retention_kept=$kept"
echo "retention_skipped=$skipped"
echo "=== PROD-H2 RETENTION COMPLETE ==="
