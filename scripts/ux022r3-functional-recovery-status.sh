#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
BACKUP_DIR="${1:-/var/backups/moneytrack/ux022r3-functional/20260811T091555Z}"
WORK="$(mktemp -d /tmp/ux022r3-recovery-status.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 failed-apply recovery status'
echo '# Gate'
echo 'DIAGNOSTIC_ONLY'
echo "HEAD=$(git rev-parse HEAD)"
echo "backup_dir=$BACKUP_DIR"

for file in moneytrack.before.dump n8n-all.before.json preview.before.tgz source-head.txt tx-write.inert.json quick-input.inert.json; do
  if [[ -s "$BACKUP_DIR/$file" ]]; then
    echo "backup_${file}=PRESENT"
  else
    echo "backup_${file}=MISSING"
  fi
done

cat > "$WORK/db-state.sql" <<'SQL'
\set ON_ERROR_STOP on
select
  case when to_regprocedure('moneytrack.finance_update_transaction_v1(bigint,bigint,bigint,text,numeric,text,text,timestamptz,bigint)') is null
    then 'ABSENT' else 'PRESENT' end as finance_update_transaction_v1;
SQL
ux022_db_psql_file "$WORK/db-state.sql"

echo '# n8n container'
docker inspect "$N8N_CONTAINER" --format 'status={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} exit_code={{.State.ExitCode}} restart_count={{.RestartCount}} started_at={{.State.StartedAt}} finished_at={{.State.FinishedAt}}' || true
docker ps -a --filter "name=^/${N8N_CONTAINER}$" --format 'container={{.Names}} status={{.Status}} image={{.Image}}' || true

echo '# n8n recent logs'
docker logs --tail 160 "$N8N_CONTAINER" 2>&1 || true

echo '# external webhook readiness now'
for spec in \
  'POST api/v1/transaction' \
  'PATCH api/v1/transaction' \
  'POST api/v1/transaction/photo' \
  'POST api/v1/transaction/text' \
  'POST api/v1/transaction/voice'
do
  method="${spec%% *}"
  path="${spec#* }"
  code="$(curl -sS --max-time 5 -X "$method" -o "$WORK/response.json" -w '%{http_code}' "$API_BASE/$path" || true)"
  body="$(tr '\n' ' ' < "$WORK/response.json" 2>/dev/null | head -c 240 || true)"
  echo "webhook method=$method path=$path http=$code body=$body"
done

echo 'DIAGNOSTIC_MUTATION=NONE'
echo 'UX022R3_RECOVERY_STATUS=COMPLETE'
