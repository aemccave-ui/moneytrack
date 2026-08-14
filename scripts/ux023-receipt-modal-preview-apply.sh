#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
WORKFLOW_ID="UX023ReceiptEditor202608"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_UX023_BACKUP_DIR:-/var/backups/moneytrack/ux023-receipt-modal/$STAMP}"
WORK="$(mktemp -d /tmp/ux023-receipt-modal.XXXXXX)"

DB_MUTATED=0
N8N_MUTATED=0
PREVIEW_MUTATED=0
WORKFLOW_EXISTED=0
SUCCESS=0

for command_name in docker curl python3 rsync tar sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "runtime_preflight=FAIL missing_command=$command_name" >&2; exit 1; }
done
docker inspect "$N8N_CONTAINER" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

echo '# Phase'
echo 'UX-023 receipt modal controlled backend + preview apply'
echo '# Gate'
echo 'CONTROLLED_MUTATION / PREVIEW_FRONTEND_ONLY / ROLLBACK_REQUIRED'
echo "HEAD=$(git rev-parse HEAD)"
echo "db_runtime_mode=$UX022_DB_MODE"
echo 'clean_checkout=PASS'

import_publish() {
  local file="$1"
  local id="$2"
  local remote="/tmp/ux023-$(basename "$file")"
  docker cp "$file" "$N8N_CONTAINER:$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="$remote" >/dev/null
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
}

export_workflow() {
  local target="$1"
  local remote="/tmp/ux023-export-$$.json"
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  if ! docker exec "$N8N_CONTAINER" n8n export:workflow --id="$WORKFLOW_ID" --output="$remote" >/dev/null 2>&1; then
    return 1
  fi
  docker cp "$N8N_CONTAINER:$remote" "$target" >/dev/null
  docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote" >/dev/null 2>&1 || true
  test -s "$target"
}

write_inert_workflow() {
  local target="$1"
  cat > "$target" <<JSON
{
  "id": "$WORKFLOW_ID",
  "name": "MoneyTrack Receipt Editor API — rollback inert",
  "nodes": [{
    "parameters": {},
    "type": "n8n-nodes-base.manualTrigger",
    "typeVersion": 1,
    "position": [0, 0],
    "id": "6f971ff1-2f71-40d3-820d-5f89978dd29f",
    "name": "Rollback Manual Trigger"
  }],
  "connections": {},
  "settings": {"executionOrder": "v1"},
  "active": false
}
JSON
}

verify_webhooks_registered() {
  local path method code
  while read -r method path; do
    code="$(curl -sS -X "$method" -H 'Content-Type: application/json' -d '{}' -o "$WORK/webhook-check.json" -w '%{http_code}' "$API_BASE/$path" || true)"
    if [[ "$code" != '401' ]]; then
      echo "receipt_webhook_readiness=FAIL method=$method path=$path http=$code" >&2
      return 1
    fi
    echo "receipt_webhook_readiness=PASS method=$method path=$path http=401"
  done <<'EOF'
GET api/v1/receipt
PATCH api/v1/receipt/currency
PATCH api/v1/receipt-item/category
EOF
}

rollback_runtime() {
  echo 'UX023_ROLLBACK=START' >&2

  if (( PREVIEW_MUTATED )); then
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    tar -C "$PREVIEW_ROOT" -xzf "$BACKUP_DIR/preview.before.tgz" \
      && echo 'rollback_preview=PASS' >&2 || echo 'rollback_preview=FAIL' >&2
  fi

  if (( N8N_MUTATED )); then
    if (( WORKFLOW_EXISTED )); then
      import_publish "$BACKUP_DIR/workflow.before.json" "$WORKFLOW_ID" \
        && echo 'rollback_workflow=PASS restored_previous' >&2 || echo 'rollback_workflow=FAIL' >&2
    else
      import_publish "$BACKUP_DIR/workflow.rollback-inert.json" "$WORKFLOW_ID" \
        && echo 'rollback_workflow=PASS published_inert' >&2 || echo 'rollback_workflow=FAIL' >&2
    fi
    docker restart "$N8N_CONTAINER" >/dev/null || true
  fi

  if (( DB_MUTATED )); then
    cat > "$WORK/drop-ux023.sql" <<'SQL'
\set ON_ERROR_STOP on
begin;
drop function if exists moneytrack.receipt_set_item_category_v2(bigint,bigint,bigint);
drop function if exists moneytrack.receipt_set_currency_v1(bigint,bigint,text);
drop function if exists moneytrack.api_receipt_detail_read_model_v1(bigint,bigint);
commit;
SQL
    if ux022_db_psql_file "$WORK/drop-ux023.sql" && ux022_db_psql_file "$BACKUP_DIR/db-functions.before.sql"; then
      echo 'rollback_db=PASS' >&2
    else
      echo 'rollback_db=FAIL' >&2
    fi
  fi

  echo "rollback_point=$BACKUP_DIR" >&2
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( ! SUCCESS )) && (( DB_MUTATED || N8N_MUTATED || PREVIEW_MUTATED )); then
    echo "UX023_RECEIPT_MODAL_APPLY=FAIL status=$status" >&2
    rollback_runtime
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap on_exit EXIT

bash "$ROOT/scripts/ux022-source-gate.sh"
echo 'source_gate=PASS'

mkdir -p "$BACKUP_DIR" "$PREVIEW_ROOT"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
tar -C "$PREVIEW_ROOT" -czf "$BACKUP_DIR/preview.before.tgz" .
test -s "$BACKUP_DIR/preview.before.tgz"

if export_workflow "$BACKUP_DIR/workflow.before.json"; then
  WORKFLOW_EXISTED=1
else
  write_inert_workflow "$BACKUP_DIR/workflow.rollback-inert.json"
fi

cat > "$WORK/db-backup.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select 'begin;';
select pg_get_functiondef(p.oid) || E';\n'
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'moneytrack'
  and p.oid in (
    to_regprocedure('moneytrack.api_receipt_detail_read_model_v1(bigint,bigint)'),
    to_regprocedure('moneytrack.receipt_set_currency_v1(bigint,bigint,text)'),
    to_regprocedure('moneytrack.receipt_set_item_category_v2(bigint,bigint,bigint)')
  );
select 'commit;';
SQL
ux022_db_psql_file "$WORK/db-backup.sql" > "$BACKUP_DIR/db-functions.before.sql"
test -s "$BACKUP_DIR/db-functions.before.sql"
echo "runtime_backup=PASS path=$BACKUP_DIR"

python3 "$ROOT/scripts/ux023-generate-receipt-editor-workflow.py" --output "$WORK/workflow.candidate.json"
python3 -m json.tool "$WORK/workflow.candidate.json" >/dev/null
echo 'workflow_candidate=PASS'

DB_MUTATED=1
ux022_db_psql_file "$ROOT/db/domain/UX-023/010_receipt_editor.sql"
echo 'backend_db_apply=PASS'

N8N_MUTATED=1
import_publish "$WORK/workflow.candidate.json" "$WORKFLOW_ID"
docker restart "$N8N_CONTAINER" >/dev/null
echo 'backend_n8n_publish_restart=PASS'

cat > "$WORK/db-verify.sql" <<'SQL'
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
select 'receipt_read_model=' || case when to_regprocedure('moneytrack.api_receipt_detail_read_model_v1(bigint,bigint)') is not null then 'PRESENT' else 'ABSENT' end;
select 'receipt_currency_write=' || case when to_regprocedure('moneytrack.receipt_set_currency_v1(bigint,bigint,text)') is not null then 'PRESENT' else 'ABSENT' end;
select 'receipt_category_write=' || case when to_regprocedure('moneytrack.receipt_set_item_category_v2(bigint,bigint,bigint)') is not null then 'PRESENT' else 'ABSENT' end;
SQL
DB_VERIFY="$(ux022_db_psql_file "$WORK/db-verify.sql")"
printf '%s\n' "$DB_VERIFY"
grep -qx 'receipt_read_model=PRESENT' <<<"$DB_VERIFY"
grep -qx 'receipt_currency_write=PRESENT' <<<"$DB_VERIFY"
grep -qx 'receipt_category_write=PRESENT' <<<"$DB_VERIFY"
echo 'backend_db_verify=PASS'

ready=0
for _ in $(seq 1 30); do
  if verify_webhooks_registered >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
if (( ! ready )); then
  verify_webhooks_registered
  exit 1
fi
verify_webhooks_registered

PREVIEW_MUTATED=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
local_asset="$(grep -oE '/assets/[^\"[:space:]]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1)"
remote_html="$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux023=$STAMP")"
remote_asset="$(printf '%s' "$remote_html" | grep -oE '/assets/[^\"[:space:]]+\.js' | head -n1)"
[[ -n "$local_asset" && "$local_asset" == "$remote_asset" ]]
local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
remote_tmp="$(mktemp)"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$remote_asset?ux023=$STAMP" -o "$remote_tmp"
remote_sha="$(sha256sum "$remote_tmp" | awk '{print $1}')"
rm -f "$remote_tmp"
[[ "$local_sha" == "$remote_sha" ]]
echo "LOCAL_ASSET=$local_asset"
echo "REMOTE_ASSET=$remote_asset"
echo "LOCAL_SHA=$local_sha"
echo "REMOTE_SHA=$remote_sha"
echo 'preview_artifact_identity=PASS'

SUCCESS=1
DB_MUTATED=0
N8N_MUTATED=0
PREVIEW_MUTATED=0
trap - EXIT
rm -rf "$WORK"

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=UX023_RECEIPT_BOUNDARIES_APPLIED'
echo 'N8N_MUTATION=UX023_RECEIPT_EDITOR_API_PUBLISHED'
echo 'PREVIEW_FRONTEND_MUTATION=APPLIED'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'UX023_RECEIPT_MODAL_APPLY=PASS'
