#!/usr/bin/env bash
set -euo pipefail

TMP="$(mktemp -d /tmp/moneytrack-prod-h4-capability.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required_command_missing=$1"
    exit 1
  }
}

for c in docker grep awk sed sort find systemctl; do
  require "$c"
done

present_env_name() {
  local container="$1" name="$2"
  docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | awk -F= -v n="$name" '$1==n {found=1} END {exit(found?0:1)}'
}

echo "=== PROD-H4 EXTERNAL CAPABILITY RESOLVER START ==="

printf '\n=== H4R / 1. AWS / OFF-HOST CAPABILITY ===\n'
if command -v aws >/dev/null 2>&1; then
  echo "aws_cli=PASS"
  if timeout 12 aws sts get-caller-identity >/dev/null 2>&1; then
    echo "aws_identity=PASS values_not_printed=PASS"
    region="$(aws configure get region 2>/dev/null || true)"
    if [ -n "$region" ]; then
      echo "aws_region=PASS value=$region"
    else
      echo "aws_region=WARN value_not_configured=true"
    fi

    if timeout 15 aws s3api list-buckets --query 'Buckets[].Name' --output text > "$TMP/buckets.txt" 2>/dev/null; then
      tr '\t' '\n' < "$TMP/buckets.txt" | sed '/^$/d' | sort -u > "$TMP/bucket-lines.txt"
      bucket_count="$(wc -l < "$TMP/bucket-lines.txt" | tr -d ' ')"
      echo "s3_list_buckets=PASS count=$bucket_count"
      grep -Ei 'moneytrack|money-track|money_track' "$TMP/bucket-lines.txt" > "$TMP/moneytrack-buckets.txt" || true
      mt_count="$(wc -l < "$TMP/moneytrack-buckets.txt" | tr -d ' ')"
      echo "s3_moneytrack_bucket_candidates=$mt_count"
      if [ "$mt_count" -gt 0 ]; then
        sed 's/^/  candidate=/' "$TMP/moneytrack-buckets.txt"
      fi
    else
      echo "s3_list_buckets=WARN accessible=false"
    fi
  else
    echo "aws_identity=WARN configured_or_reachable=false"
  fi
else
  echo "aws_cli=WARN present=false"
fi

if command -v rsync >/dev/null 2>&1; then echo "rsync_cli=PASS"; else echo "rsync_cli=WARN present=false"; fi

remote_mounts="$(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null | grep -Ei ' (nfs|nfs4|cifs|sshfs|fuse\.rclone|s3fs|davfs|fuse\.sshfs)( |$)' || true)"
if [ -n "$remote_mounts" ]; then
  echo "existing_remote_mount=PASS"
  printf '%s\n' "$remote_mounts" | sed 's/^/  /'
else
  echo "existing_remote_mount=WARN present=false"
fi

printf '\n=== H4R / 2. ALERT DELIVERY INPUTS ===\n'
if present_env_name n8n MONEYTRACK_BOT_TOKEN; then
  echo "moneytrack_bot_token_runtime=PASS value_not_printed=PASS"
else
  echo "moneytrack_bot_token_runtime=WARN present=false"
fi

# Report only variable names, never values, from known runtime/config sources.
{
  docker inspect n8n --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= '{print $1}'
  for f in /home/adm_mt/moneytrack-automation/config/n8n.env /root/stack/n8n/.env; do
    if [ -f "$f" ]; then
      sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' "$f"
    fi
  done
} | grep -Ei '(^|_)(ALERT|ADMIN|OPERATOR|CHAT|TELEGRAM|BOT)(_|$)|MONEYTRACK_BOT_TOKEN' | sort -u > "$TMP/alert-env-names.txt" || true

alert_name_count="$(wc -l < "$TMP/alert-env-names.txt" | tr -d ' ')"
echo "alert_related_env_names=$alert_name_count values_not_printed=PASS"
if [ "$alert_name_count" -gt 0 ]; then
  sed 's/^/  env_name=/' "$TMP/alert-env-names.txt"
fi

# Inspect schema metadata only; no user/chat values are emitted.
docker exec moneytrack-db psql -U moneytrack -d moneytrack -Atc \
  "select table_schema||'.'||table_name||'.'||column_name from information_schema.columns where table_schema not in ('pg_catalog','information_schema') and column_name ~* '(telegram|chat|user_id)' order by 1" \
  > "$TMP/operator-columns.txt" 2>/dev/null || true
operator_col_count="$(wc -l < "$TMP/operator-columns.txt" | tr -d ' ')"
echo "operator_identity_schema_candidates=$operator_col_count values_not_printed=PASS"
if [ "$operator_col_count" -gt 0 ]; then
  sed 's/^/  schema_column=/' "$TMP/operator-columns.txt"
fi

for t in mail mailx sendmail; do
  if command -v "$t" >/dev/null 2>&1; then
    echo "local_mail_transport=PASS command=$t"
    break
  fi
done

printf '\n=== H4R / 3. EXISTING FAILURE HOOKS ===\n'
onfailure="$(grep -RIlE '^[[:space:]]*OnFailure=' /etc/systemd/system 2>/dev/null | grep -Ei 'moneytrack|certbot' || true)"
if [ -n "$onfailure" ]; then
  echo "moneytrack_onfailure_hook=PASS"
  printf '%s\n' "$onfailure" | sed 's/^/  /'
else
  echo "moneytrack_onfailure_hook=WARN present=false"
fi

echo "=== PROD-H4 EXTERNAL CAPABILITY RESOLVER COMPLETE ==="
