#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Controlled UX-022R3 functional runtime apply.
# Mutates only:
#   - additive DB function moneytrack.finance_update_transaction_v1
#   - two new n8n workflows UX022TxWrite202608 / UX022QuickInput202608
#   - preview frontend /var/www/moneytrack-miniapp-preview
# It has no production-frontend target.

source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_R3_FUNCTIONAL_BACKUP_DIR:-/var/backups/moneytrack/ux022r3-functional/$STAMP}"
WORK="$(mktemp -d /tmp/ux022r3-functional-apply.XXXXXX)"

DB_MUTATED=0
N8N_MUTATED=0
PREVIEW_MUTATED=0
SUCCESS=0

cleanup() {
  rm -rf "$WORK"
}

[[ "$PREVIEW_ROOT" == "/var/www/moneytrack-miniapp-preview" ]] || {
  echo "preview_target_guard=FAIL root=$PREVIEW_ROOT" >&2
  exit 1
}
[[ "$PREVIEW_URL" == "https://preview.moneytrackapp.xyz" ]] || {
  echo "preview_target_guard=FAIL url=$PREVIEW_URL" >&2
  exit 1
}

docker inspect "$N8N_CONTAINER" >/dev/null
for command_name in docker curl rsync tar sha256sum python3 npm; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "runtime_preflight=FAIL missing_command=$command_name" >&2
    exit 1
  }
done

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

echo '# Phase'
echo 'UX-022R3 functional runtime + preview apply'
echo '# Gate'
echo 'CONTROLLED_MUTATION / PREVIEW_ONLY_FRONTEND'
echo "HEAD=$(git rev-parse HEAD)"
echo 'preview_target_guard=PASS'
echo 'clean_checkout=PASS'

bash "$ROOT/scripts/ux022r3-functional-gate.sh"
echo 'functional_preflight=PASS'

python3 "$ROOT/scripts/ux022r3-generate-transaction-write-workflow.py" --output "$WORK/tx-write.json"
python3 "$ROOT/scripts/ux022r3-generate-quick-input-workflow.py" --output "$WORK/quick-input.json"

cat > "$WORK/db-absence.sql" <<'SQL'
\set ON_ERROR_STOP on
do $$
begin
  if to_regprocedure('moneytrack.finance_update_transaction_v1(bigint,bigint,bigint,text,numeric,text,text,timestamptz,bigint)') is not null then
    raise exception 'UX022R3_TX_UPDATE_FUNCTION_ALREADY_EXISTS';
  end if;
end $$;
SQL
ux022_db_psql_file "$WORK/db-absence.sql"
echo 'db_additive_object_absent=PASS'

docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-functional-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-functional-all.json" "$WORK/n8n-all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-functional-all.json
python3 - "$WORK/n8n-all.json" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=raw if isinstance(raw,list) else [raw]
ids={str(w.get('id')) for w in workflows}
for wanted in ('UX022TxWrite202608','UX022QuickInput202608'):
    assert wanted not in ids, f'workflow_id_already_exists={wanted}'
print('n8n_additive_workflow_ids_absent=PASS')
PY

mkdir -p "$BACKUP_DIR" "$PREVIEW_ROOT"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
ux022_db_pg_dump_schema moneytrack "$BACKUP_DIR/moneytrack.before.dump"
test -s "$BACKUP_DIR/moneytrack.before.dump"
cp "$WORK/n8n-all.json" "$BACKUP_DIR/n8n-all.before.json"
tar -C "$PREVIEW_ROOT" -czf "$BACKUP_DIR/preview.before.tgz" .
test -s "$BACKUP_DIR/preview.before.tgz"
echo "runtime_backup=PASS path=$BACKUP_DIR"

python3 - "$BACKUP_DIR/tx-write.inert.json" "$BACKUP_DIR/quick-input.inert.json" <<'PY'
import json,sys
from pathlib import Path
for path,wid,name in [
    (sys.argv[1],'UX022TxWrite202608','MoneyTrack Transaction Write API — rollback inert'),
    (sys.argv[2],'UX022QuickInput202608','MoneyTrack MiniApp Quick Input API — rollback inert'),
]:
    Path(path).write_text(json.dumps({
        'id':wid,'name':name,'nodes':[],'connections':{},'settings':{'executionOrder':'v1'},'active':False
    },ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY

import_publish() {
  local file="$1"
  local id="$2"
  local name="$(basename "$file")"
  docker cp "$file" "$N8N_CONTAINER:/tmp/$name" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="/tmp/$name"
  docker exec "$N8N_CONTAINER" n8n publish:workflow --id="$id"
}

import_inert() {
  local file="$1"
  local name="$(basename "$file")"
  docker cp "$file" "$N8N_CONTAINER:/tmp/$name" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="/tmp/$name"
}

rollback() {
  local status="${1:-1}"
  trap - ERR EXIT
  echo "UX022R3_FUNCTIONAL_PREVIEW_APPLY=FAIL status=$status" >&2

  if (( PREVIEW_MUTATED )); then
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    tar -C "$PREVIEW_ROOT" -xzf "$BACKUP_DIR/preview.before.tgz" \
      && echo 'rollback_preview=PASS' >&2 \
      || echo 'rollback_preview=FAIL' >&2
  fi

  if (( N8N_MUTATED )); then
    import_inert "$BACKUP_DIR/tx-write.inert.json" || echo 'rollback_tx_write_inert=FAIL' >&2
    import_inert "$BACKUP_DIR/quick-input.inert.json" || echo 'rollback_quick_input_inert=FAIL' >&2
    docker restart "$N8N_CONTAINER" >/dev/null || echo 'rollback_n8n_restart=FAIL' >&2
    echo 'rollback_n8n_new_routes=ATTEMPTED' >&2
  fi

  if (( DB_MUTATED )); then
    cat > "$WORK/drop-050.sql" <<'SQL'
\set ON_ERROR_STOP on
begin;
drop function if exists moneytrack.finance_update_transaction_v1(bigint,bigint,bigint,text,numeric,text,text,timestamptz,bigint);
commit;
SQL
    ux022_db_psql_file "$WORK/drop-050.sql" || echo 'rollback_db_function=FAIL' >&2
  fi

  echo "rollback_point=$BACKUP_DIR" >&2
  cleanup
  exit "$status"
}

on_exit() {
  local status=$?
  if (( status != 0 && SUCCESS == 0 && (DB_MUTATED || N8N_MUTATED || PREVIEW_MUTATED) )); then
    rollback "$status"
  fi
  cleanup
}
trap 'rollback $?' ERR
trap on_exit EXIT

ux022_db_psql_file "$ROOT/db/domain/UX-022/050_transaction_editor_write.sql"
DB_MUTATED=1
echo 'db_transaction_editor_apply=PASS'

N8N_MUTATED=1
import_publish "$WORK/tx-write.json" UX022TxWrite202608
import_publish "$WORK/quick-input.json" UX022QuickInput202608
docker restart "$N8N_CONTAINER" >/dev/null
echo 'n8n_new_adapters_publish=PASS'

readiness=(
  'POST api/v1/transaction'
  'PATCH api/v1/transaction'
  'POST api/v1/transaction/photo'
  'POST api/v1/transaction/text'
  'POST api/v1/transaction/voice'
)
for spec in "${readiness[@]}"; do
  method="${spec%% *}"
  path="${spec#* }"
  ready=0
  code=''
  for _ in $(seq 1 20); do
    code="$(curl -sS -X "$method" -o "$WORK/readiness.json" -w '%{http_code}' "$API_BASE/$path" || true)"
    if [[ "$code" == '401' ]]; then ready=1; break; fi
    sleep 1
  done
  if (( ! ready )); then
    echo "new_webhook_readiness=FAIL method=$method path=$path http=$code" >&2
    false
  fi
  echo "new_webhook_readiness=PASS method=$method path=$path"
done

PREVIEW_MUTATED=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo 'preview_rsync=PASS'

local_asset="$(grep -oE '/assets/[^\"[:space:]]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1)"
remote_html="$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux022r3fn=$STAMP")"
remote_asset="$(printf '%s' "$remote_html" | grep -oE '/assets/[^\"[:space:]]+\.js' | head -n1)"
[[ -n "$local_asset" && "$local_asset" == "$remote_asset" ]]
local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
remote_tmp="$WORK/remote.js"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$remote_asset?ux022r3fn=$STAMP" -o "$remote_tmp"
remote_sha="$(sha256sum "$remote_tmp" | awk '{print $1}')"
[[ "$local_sha" == "$remote_sha" ]]

echo "LOCAL_ASSET=$local_asset"
echo "REMOTE_ASSET=$remote_asset"
echo "LOCAL_SHA=$local_sha"
echo "REMOTE_SHA=$remote_sha"
echo 'preview_artifact_identity=PASS'

SUCCESS=1
PREVIEW_MUTATED=0
trap - ERR

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=finance_update_transaction_v1_APPLIED'
echo 'N8N_MUTATION=UX022TxWrite202608,UX022QuickInput202608_PUBLISHED'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'UX022R3_FUNCTIONAL_PREVIEW_APPLY=PASS'
