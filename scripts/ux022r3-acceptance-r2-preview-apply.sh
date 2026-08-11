#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"
ux022_db_init

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
PREVIEW_ROOT="${MONEYTRACK_PREVIEW_ROOT:-/var/www/moneytrack-miniapp-preview}"
PREVIEW_URL="${MONEYTRACK_PREVIEW_URL:-https://preview.moneytrackapp.xyz}"
API_BASE="${MONEYTRACK_API_BASE:-https://n8n.moneytrackapp.xyz/webhook}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${MONEYTRACK_R3_R2_BACKUP_DIR:-/var/backups/moneytrack/ux022r3-acceptance-r2/$STAMP}"
WORK="$(mktemp -d /tmp/ux022r3-r2-apply.XXXXXX)"

DB_MUTATED=0
N8N_MUTATED=0
PREVIEW_MUTATED=0
SUCCESS=0

[[ "$PREVIEW_ROOT" == "/var/www/moneytrack-miniapp-preview" ]] || { echo "preview_target_guard=FAIL root=$PREVIEW_ROOT" >&2; exit 1; }
[[ "$PREVIEW_URL" == "https://preview.moneytrackapp.xyz" ]] || { echo "preview_target_guard=FAIL url=$PREVIEW_URL" >&2; exit 1; }

for command_name in docker curl rsync tar sha256sum python3 npm; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "runtime_preflight=FAIL missing_command=$command_name" >&2; exit 1; }
done
docker inspect "$N8N_CONTAINER" >/dev/null

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo 'clean_checkout=FAIL' >&2
  git status --short >&2
  exit 1
fi

import_inert() {
  local file="$1"
  local name
  name="$(basename "$file")"
  docker cp "$file" "$N8N_CONTAINER:/tmp/$name" >/dev/null
  docker exec "$N8N_CONTAINER" n8n import:workflow --input="/tmp/$name"
}

rollback_runtime() {
  echo 'round2_rollback=START' >&2
  if (( PREVIEW_MUTATED )) && [[ -s "$BACKUP_DIR/preview.before.tgz" ]]; then
    rm -rf "$PREVIEW_ROOT"
    mkdir -p "$PREVIEW_ROOT"
    tar -C "$PREVIEW_ROOT" -xzf "$BACKUP_DIR/preview.before.tgz" \
      && echo 'rollback_preview=PASS' >&2 \
      || echo 'rollback_preview=FAIL' >&2
  fi

  if (( N8N_MUTATED )) && [[ -s "$BACKUP_DIR/transfer-write.inert.json" ]]; then
    import_inert "$BACKUP_DIR/transfer-write.inert.json" \
      && echo 'rollback_transfer_workflow_inert=PASS' >&2 \
      || echo 'rollback_transfer_workflow_inert=FAIL' >&2
    docker restart "$N8N_CONTAINER" >/dev/null || echo 'rollback_n8n_restart=FAIL' >&2
  fi

  if (( DB_MUTATED )); then
    cat > "$WORK/drop-transfer-editor.sql" <<'SQL'
\set ON_ERROR_STOP on
begin;
drop function if exists moneytrack.finance_get_transfer_v1(bigint,bigint);
drop function if exists moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text);
drop function if exists moneytrack.finance_delete_transfer_v1(bigint,bigint);
commit;
SQL
    ux022_db_psql_file "$WORK/drop-transfer-editor.sql" \
      && echo 'rollback_transfer_db_functions=PASS' >&2 \
      || echo 'rollback_transfer_db_functions=FAIL' >&2
  fi
  echo "rollback_point=$BACKUP_DIR" >&2
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( ! SUCCESS )) && (( DB_MUTATED || N8N_MUTATED || PREVIEW_MUTATED )); then
    echo "UX022R3_ACCEPTANCE_R2_PREVIEW_APPLY=FAIL status=$status" >&2
    rollback_runtime
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap on_exit EXIT

echo '# Phase'
echo 'UX-022R3 Telegram acceptance round 2 runtime + preview'
echo '# Gate'
echo 'CONTROLLED_MUTATION / PREVIEW_ONLY_FRONTEND'
echo "HEAD=$(git rev-parse HEAD)"
echo 'preview_target_guard=PASS'
echo 'clean_checkout=PASS'

# No mutation before latest source + transfer rollback-only preflight.
bash "$ROOT/scripts/ux022r3-acceptance-r2-gate.sh"
echo 'round2_preflight=PASS'

python3 "$ROOT/scripts/ux022r3-generate-transfer-write-workflow.py" --output "$WORK/transfer-write.json"

cat > "$WORK/db-absence.sql" <<'SQL'
\set ON_ERROR_STOP on
do $$
begin
  if to_regprocedure('moneytrack.finance_get_transfer_v1(bigint,bigint)') is not null
     or to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)') is not null
     or to_regprocedure('moneytrack.finance_delete_transfer_v1(bigint,bigint)') is not null
  then
    raise exception 'UX022R3_TRANSFER_EDITOR_FUNCTION_ALREADY_EXISTS';
  end if;
end $$;
SQL
ux022_db_psql_file "$WORK/db-absence.sql"
echo 'transfer_db_additive_objects_absent=PASS'

docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-r2-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-r2-all.json" "$WORK/n8n-all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-r2-all.json
python3 - "$WORK/n8n-all.json" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=raw if isinstance(raw,list) else [raw]
assert 'UX022TransferWrite202608' not in {str(w.get('id')) for w in workflows}, 'transfer_workflow_id_already_exists'
print('transfer_workflow_id_absent=PASS')
PY

mkdir -p "$BACKUP_DIR" "$PREVIEW_ROOT"
printf '%s\n' "$(git rev-parse HEAD)" > "$BACKUP_DIR/source-head.txt"
ux022_db_pg_dump_schema moneytrack "$BACKUP_DIR/moneytrack.before.dump"
test -s "$BACKUP_DIR/moneytrack.before.dump"
cp "$WORK/n8n-all.json" "$BACKUP_DIR/n8n-all.before.json"
tar -C "$PREVIEW_ROOT" -czf "$BACKUP_DIR/preview.before.tgz" .
test -s "$BACKUP_DIR/preview.before.tgz"
python3 - "$BACKUP_DIR/transfer-write.inert.json" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  'id':'UX022TransferWrite202608',
  'name':'MoneyTrack Transfer Editor API — rollback inert',
  'nodes':[],
  'connections':{},
  'settings':{'executionOrder':'v1'},
  'active':False,
},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
PY
echo "runtime_backup=PASS path=$BACKUP_DIR"

ux022_db_psql_file "$ROOT/db/domain/UX-022/055_transfer_editor_write.sql"
DB_MUTATED=1
echo 'transfer_db_apply=PASS'

N8N_MUTATED=1
docker cp "$WORK/transfer-write.json" "$N8N_CONTAINER:/tmp/ux022r3-transfer-write.json" >/dev/null
docker exec "$N8N_CONTAINER" n8n import:workflow --input=/tmp/ux022r3-transfer-write.json
docker exec "$N8N_CONTAINER" n8n publish:workflow --id=UX022TransferWrite202608
docker restart "$N8N_CONTAINER" >/dev/null
echo 'transfer_n8n_publish=PASS'

# Missing-auth readiness is non-mutating and waits long enough for webhook registration.
readiness=(
  'GET api/v1/transfer'
  'POST api/v1/transfer'
  'PATCH api/v1/transfer'
  'DELETE api/v1/transfer'
)
for spec in "${readiness[@]}"; do
  method="${spec%% *}"
  path="${spec#* }"
  ready=0
  code=''
  for _ in $(seq 1 45); do
    code="$(curl -sS -X "$method" -o "$WORK/readiness.json" -w '%{http_code}' "$API_BASE/$path" || true)"
    if [[ "$code" == '401' ]]; then ready=1; break; fi
    sleep 2
  done
  if (( ! ready )); then
    echo "transfer_webhook_readiness=FAIL method=$method path=$path http=$code" >&2
    exit 1
  fi
  echo "transfer_webhook_readiness=PASS method=$method path=$path"
done

PREVIEW_MUTATED=1
rsync -a --delete "$ROOT/miniapp/dist/" "$PREVIEW_ROOT/"
echo 'preview_rsync=PASS'

local_asset="$(grep -oE '/assets/[^\"[:space:]]+\.js' "$ROOT/miniapp/dist/index.html" | head -n1)"
remote_html="$(curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL/?ux022r3r2=$STAMP")"
remote_asset="$(printf '%s' "$remote_html" | grep -oE '/assets/[^\"[:space:]]+\.js' | head -n1)"
[[ -n "$local_asset" && "$local_asset" == "$remote_asset" ]]
local_sha="$(sha256sum "$ROOT/miniapp/dist$local_asset" | awk '{print $1}')"
remote_tmp="$WORK/remote.js"
curl -fsS -H 'Cache-Control: no-cache' "$PREVIEW_URL$remote_asset?ux022r3r2=$STAMP" -o "$remote_tmp"
remote_sha="$(sha256sum "$remote_tmp" | awk '{print $1}')"
[[ "$local_sha" == "$remote_sha" ]]
echo "LOCAL_ASSET=$local_asset"
echo "REMOTE_ASSET=$remote_asset"
echo "LOCAL_SHA=$local_sha"
echo "REMOTE_SHA=$remote_sha"
echo 'preview_artifact_identity=PASS'

SUCCESS=1
PREVIEW_MUTATED=0

echo "rollback_point=$BACKUP_DIR"
echo 'DB_MUTATION=transfer_editor_functions_APPLIED'
echo 'N8N_MUTATION=UX022TransferWrite202608_PUBLISHED'
echo 'PRODUCTION_FRONTEND_MUTATION=NONE'
echo 'UX022R3_ACCEPTANCE_R2_PREVIEW_APPLY=PASS'
