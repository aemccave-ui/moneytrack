#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"

N8N_CONTAINER="${MONEYTRACK_N8N_CONTAINER:-n8n}"
WORK="$(mktemp -d /tmp/ux022r3-transfer-write.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 transfer editor contract'
echo '# Gate'
echo 'READ_ONLY / ROLLBACK_ONLY'

python3 -m py_compile scripts/ux022r3-generate-transfer-write-workflow.py
python3 scripts/ux022r3-generate-transfer-write-workflow.py --output "$WORK/transfer-write.json"

python3 - "$WORK/transfer-write.json" <<'PY'
import json,sys
from pathlib import Path
wf=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
assert wf['id']=='UX022TransferWrite202608'
webhooks=[n for n in wf['nodes'] if n.get('type')=='n8n-nodes-base.webhook']
routes={(n['parameters'].get('httpMethod','GET'),n['parameters'].get('path')) for n in webhooks}
assert routes=={
    ('GET','api/v1/transfer'),
    ('POST','api/v1/transfer'),
    ('PATCH','api/v1/transfer'),
    ('DELETE','api/v1/transfer'),
}
queries=[n['parameters']['query'].strip().lower() for n in wf['nodes'] if n.get('type')=='n8n-nodes-base.postgres']
assert len(queries)==4
assert all(q.startswith('select * from moneytrack.') for q in queries)
assert any('finance_get_transfer_v1' in q for q in queries)
assert any('finance_create_transfer_v1' in q for q in queries)
assert any('finance_update_transfer_v1' in q for q in queries)
assert any('finance_delete_transfer_v1' in q for q in queries)
assert all('from moneytrack.app_users' in q for q in queries)
assert not any(token in '\n'.join(queries) for token in ('insert into ','update moneytrack.','delete from '))
verify=[n for n in wf['nodes'] if n.get('type')=='n8n-nodes-base.code' and n.get('name','').endswith(' Verify')]
assert len(verify)==4
assert all('moneytrackVerifyTelegramInitData' in n['parameters'].get('jsCode','') for n in verify)
print('transfer_write_workflow_static=PASS')
PY

docker inspect "$N8N_CONTAINER" >/dev/null
docker exec "$N8N_CONTAINER" n8n export:workflow --all --output=/tmp/ux022r3-transfer-gate-all.json >/dev/null
docker cp "$N8N_CONTAINER:/tmp/ux022r3-transfer-gate-all.json" "$WORK/all.json" >/dev/null
docker exec "$N8N_CONTAINER" rm -f /tmp/ux022r3-transfer-gate-all.json
python3 - "$WORK/all.json" <<'PY'
import json,sys
from pathlib import Path
raw=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
workflows=raw if isinstance(raw,list) else [raw]
wanted={
    ('GET','api/v1/transfer'),
    ('POST','api/v1/transfer'),
    ('PATCH','api/v1/transfer'),
    ('DELETE','api/v1/transfer'),
}
owners=[]
for wf in workflows:
    for node in wf.get('nodes',[]):
        if node.get('type')!='n8n-nodes-base.webhook':
            continue
        p=node.get('parameters') or {}
        key=(p.get('httpMethod','GET'),p.get('path'))
        if key in wanted:
            owners.append((key,wf.get('id'),wf.get('name'),wf.get('active')))
if owners:
    for row in owners: print('transfer_route_collision=',row)
    raise SystemExit('TRANSFER_EDITOR_ROUTE_COLLISION')
print('transfer_editor_routes_free=PASS')
PY

ux022_db_init
echo "db_runtime_mode=$UX022_DB_MODE"

sed -E '/^[[:space:]]*(begin|commit);[[:space:]]*$/Id' \
  db/domain/UX-022/055_transfer_editor_write.sql > "$WORK/055.body.sql"
cat > "$WORK/validate.sql" <<'SQL'
\set ON_ERROR_STOP on
begin;
SQL
cat "$WORK/055.body.sql" >> "$WORK/validate.sql"
cat >> "$WORK/validate.sql" <<'SQL'
do $$
declare
  v_def text;
begin
  if to_regprocedure('moneytrack.finance_get_transfer_v1(bigint,bigint)') is null then
    raise exception 'TRANSFER_GET_FUNCTION_MISSING';
  end if;
  if to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)') is null then
    raise exception 'TRANSFER_UPDATE_FUNCTION_MISSING';
  end if;
  if to_regprocedure('moneytrack.finance_delete_transfer_v1(bigint,bigint)') is null then
    raise exception 'TRANSFER_DELETE_FUNCTION_MISSING';
  end if;

  select pg_get_functiondef(to_regprocedure('moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamp with time zone,text)')) into v_def;
  if position('SAME_ACCOUNT_TRANSFER_FORBIDDEN' in v_def)=0 then raise exception 'TRANSFER_SAME_ACCOUNT_GUARD_MISSING'; end if;
  if position('finance_fx_convert_usd_bridge_v1' in v_def)=0 then raise exception 'TRANSFER_FX_BOUNDARY_MISSING'; end if;
  if position('TRANSFER_NOT_FOUND_OR_NOT_OWNED' in v_def)=0 then raise exception 'TRANSFER_OWNERSHIP_GUARD_MISSING'; end if;
end $$;
rollback;
\echo UX022R3_TRANSFER_DB_ROLLBACK_ONLY=PASS
SQL

ux022_db_psql_file "$WORK/validate.sql"
echo 'TRANSFER_EDITOR_GATE=PASS'
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
echo 'FRONTEND_MUTATION=NONE'
