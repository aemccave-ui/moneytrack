#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/ux022-db-runtime.sh"

WORK="$(mktemp -d /tmp/ux022r3-tx-write.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo '# Phase'
echo 'UX-022R3 transaction write contract'
echo '# Gate'
echo 'ROLLBACK_ONLY'

python3 scripts/ux022r3-generate-transaction-write-workflow.py --output "$WORK/tx-write.json"
python3 - "$WORK/tx-write.json" <<'PY'
import json,sys
from pathlib import Path
wf=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
assert wf['id']=='UX022TxWrite202608'
webhooks=[n for n in wf['nodes'] if n.get('type')=='n8n-nodes-base.webhook']
assert {(n['parameters'].get('httpMethod','GET'),n['parameters'].get('path')) for n in webhooks} == {('POST','api/v1/transaction'),('PATCH','api/v1/transaction')}
queries=[n['parameters']['query'].strip().lower() for n in wf['nodes'] if n.get('type')=='n8n-nodes-base.postgres']
assert len(queries)==2
assert all(q.startswith('select * from moneytrack.') for q in queries)
assert not any(token in '\n'.join(queries) for token in ('insert into ','update moneytrack.','delete from '))
assert any('finance_create_transaction_v1' in q for q in queries)
assert any('finance_update_transaction_v1' in q for q in queries)
assert all('from moneytrack.app_users u' in q for q in queries)
assert all('where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint' in q for q in queries)
assert not any('finance_create_transaction_v1(\n  {{ $json.telegram_user_id }}' in q for q in queries)
assert not any('finance_update_transaction_v1(\n  {{ $json.telegram_user_id }}' in q for q in queries)
print('transaction_write_internal_user_resolution=PASS')
print('transaction_write_workflow_static=PASS')
PY

ux022_db_init
echo "db_runtime_mode=$UX022_DB_MODE"

sed -E '/^[[:space:]]*(begin|commit);[[:space:]]*$/Id' \
  db/domain/UX-022/050_transaction_editor_write.sql > "$WORK/050.body.sql"
cat > "$WORK/validate.sql" <<'SQL'
\set ON_ERROR_STOP on
begin;
SQL
cat "$WORK/050.body.sql" >> "$WORK/validate.sql"
cat >> "$WORK/validate.sql" <<'SQL'
do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid)
    into v_def
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='moneytrack'
     and p.proname='finance_update_transaction_v1'
   order by p.oid desc
   limit 1;
  if v_def is null then raise exception 'TX_UPDATE_FUNCTION_MISSING'; end if;
  if position('TRANSACTION_TRANSFER_EDIT_UNSUPPORTED' in v_def)=0 then raise exception 'TX_UPDATE_TRANSFER_GUARD_MISSING'; end if;
  if position('ACCOUNT_GROUP_NOT_POSTABLE' in v_def)=0 then raise exception 'TX_UPDATE_GROUP_GUARD_MISSING'; end if;
  if position('finance_fx_convert_usd_bridge_v1' in v_def)=0 then raise exception 'TX_UPDATE_FX_BOUNDARY_MISSING'; end if;
end $$;
rollback;
\echo UX022R3_TX_WRITE_DB_ROLLBACK_ONLY=PASS
SQL

ux022_db_psql_file "$WORK/validate.sql"
echo 'transaction_write_gate=PASS'
echo 'DB_MUTATION=NONE'
echo 'N8N_MUTATION=NONE'
