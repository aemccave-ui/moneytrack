#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

set -a
source /home/adm_mt/moneytrack-automation/config/n8n.env
set +a

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API3C_WORK_DIR:-/tmp/api-3c-ownership-idempotency}"
rm -rf "$WORK"
mkdir -p "$WORK"

DEL_ID="MTxDel7Qp2Vn9Kc4"


echo "=== API-3C / 1. ACTIVE HTTP MUTATION SURFACE ==="
docker exec postgres \
  psql -U n8n -d n8n -P pager=off -c "
select
    w.id workflow_id,
    w.name workflow_name,
    n->>'name' node_name,
    upper(coalesce(n->'parameters'->>'httpMethod','GET')) method,
    '/' || ltrim(coalesce(n->'parameters'->>'path',''),'/') path,
    coalesce(n->'parameters'->>'authentication','none') webhook_authentication,
    w.active,
    (w.\"versionId\" = w.\"activeVersionId\") version_consistent
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and upper(coalesce(n->'parameters'->>'httpMethod','GET')) in ('POST','PUT','PATCH','DELETE')
order by path,method;
"

mutation_count="$(docker exec postgres psql -U n8n -d n8n -Atc "
select count(*)
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and upper(coalesce(n->'parameters'->>'httpMethod','GET')) in ('POST','PUT','PATCH','DELETE')
  and ('/' || ltrim(coalesce(n->'parameters'->>'path',''),'/')) like '/api/v1/%';
")"

echo "retained_api_mutation_endpoint_count=$mutation_count"
if [ "$mutation_count" != "1" ]; then
  echo "expected exactly one retained /api/v1 mutation endpoint"
  exit 1
fi

owner_count="$(docker exec postgres psql -U n8n -d n8n -Atc "
select count(*)
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and w.id='$DEL_ID'
  and n->>'type'='n8n-nodes-base.webhook'
  and upper(coalesce(n->'parameters'->>'httpMethod','GET'))='DELETE'
  and ('/' || ltrim(coalesce(n->'parameters'->>'path',''),'/'))='/api/v1/transaction';
")"
if [ "$owner_count" != "1" ]; then
  echo "DELETE /api/v1/transaction ownership mismatch count=$owner_count"
  exit 1
fi

echo "retained_write_surface=PASS"


echo
echo "=== API-3C / 2. FRESH DELETE WORKFLOW SNAPSHOT ==="
curl -fsS \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  "$BASE/api/v1/workflows/$DEL_ID" \
  > "$WORK/delete.json"

jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/delete.json"
jq -e '.active == true and .versionId == .activeVersionId' "$WORK/delete.json" >/dev/null
echo "delete_identity_gate=PASS"


echo
echo "=== API-3C / 3. DELETE WORKFLOW DATA PATH ==="
python3 - "$WORK/delete.json" <<'PY'
import json
import re
import sys

wf = json.load(open(sys.argv[1], encoding='utf-8'))
pg = [n for n in wf.get('nodes', []) if n.get('type') == 'n8n-nodes-base.postgres']
print(f"postgres_nodes={len(pg)}")

boundary = []
direct_mutation = []
for n in pg:
    q = str((n.get('parameters') or {}).get('query') or '')
    if 'finance_delete_transaction_v1' in q:
        boundary.append((n.get('name'), q))
    if re.search(r'(?is)\b(insert\s+into|update|delete\s+from)\s+moneytrack\.[A-Za-z_][A-Za-z0-9_]*', q):
        direct_mutation.append(n.get('name'))

for name, q in boundary:
    print(f"backend_boundary_node={name}")
    compact = ' '.join(q.split())
    print(f"backend_boundary_query={compact}")

print(f"finance_delete_transaction_boundary_count={len(boundary)}")
print(f"direct_business_mutation_nodes={direct_mutation}")

if len(boundary) != 1:
    raise SystemExit('expected exactly one finance_delete_transaction_v1 call')
if direct_mutation:
    raise SystemExit('delete workflow contains direct business-table mutation')

# API-3B canonical auth must still be present.
auth = []
for n in wf.get('nodes', []):
    if n.get('type') != 'n8n-nodes-base.code':
        continue
    js = str((n.get('parameters') or {}).get('jsCode') or '')
    if 'MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION=api3b-v1' in js:
        auth.append(n.get('name'))
print(f"canonical_auth_nodes={auth}")
if len(auth) != 1:
    raise SystemExit(f'expected exactly one canonical auth node in delete workflow, got {len(auth)}')

print('delete_workflow_boundary_gate=PASS')
PY


echo
echo "=== API-3C / 4. BACKEND FUNCTION SIGNATURE ==="
docker exec moneytrack-db \
  psql -U moneytrack -d moneytrack -P pager=off -c "
select
    p.oid::regprocedure as function_identity,
    pg_get_function_identity_arguments(p.oid) as identity_arguments,
    pg_get_function_result(p.oid) as result_type,
    case p.prosecdef when true then 'SECURITY DEFINER' else 'SECURITY INVOKER' end security_mode,
    p.provolatile as volatility
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='moneytrack'
  and p.proname='finance_delete_transaction_v1'
order by p.oid;
"

fn_count="$(docker exec moneytrack-db psql -U moneytrack -d moneytrack -Atc "
select count(*)
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='moneytrack'
  and p.proname='finance_delete_transaction_v1';
")"
if [ "$fn_count" != "1" ]; then
  echo "finance_delete_transaction_v1 expected exactly once, got $fn_count"
  exit 1
fi
echo "backend_function_identity_gate=PASS"


echo
echo "=== API-3C / 5. BACKEND FUNCTION DEFINITION ==="
docker exec moneytrack-db \
  psql -U moneytrack -d moneytrack -P pager=off -Atc "
select pg_get_functiondef(p.oid)
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='moneytrack'
  and p.proname='finance_delete_transaction_v1';
" | tee "$WORK/finance_delete_transaction_v1.sql"

python3 - "$WORK/finance_delete_transaction_v1.sql" <<'PY'
import re
import sys
from pathlib import Path

s = Path(sys.argv[1]).read_text(encoding='utf-8')
sl = s.lower()

markers = {
    'mentions_user_id': 'user_id' in sl,
    'mentions_transaction_id': 'transaction' in sl and ('transaction_id' in sl or 'p_transaction' in sl),
    'deletes_transactions': bool(re.search(r'\bdelete\s+from\s+moneytrack\.transactions\b', sl)),
    'has_delete_returning_or_result': ('returning' in sl or 'deleted' in sl or 'not_found' in sl),
}
for k, v in markers.items():
    print(f"{k}={'PASS' if v else 'ABSENT'}")

# Extract business DML targets for review.
targets = []
for m in re.finditer(r'\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\.([a-z_][a-z0-9_]*)', sl):
    targets.append(m.group(1))
print(f"backend_dml_targets={sorted(set(targets))}")

# Ownership evidence must exist in the function itself, not only in n8n.
# We require both the transaction target and user identity to participate in
# the implementation text; exact predicate is printed above for final review.
if not markers['mentions_user_id']:
    raise SystemExit('backend function has no user_id ownership marker')
if not markers['mentions_transaction_id']:
    raise SystemExit('backend function has no transaction-id marker')
if not markers['deletes_transactions']:
    raise SystemExit('backend function does not delete moneytrack.transactions')

print('backend_ownership_marker_gate=PASS')
PY


echo
echo "=== API-3C / 6. GLOBAL ZERO-WRITER REASSERTION ==="
docker exec postgres \
  psql -U n8n -d n8n -P pager=off -Atc "
with nodes as (
    select coalesce(n->'parameters'->>'query','') query_text
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active=true
)
select count(*)
from nodes
where query_text ~*
  '(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\\.[a-zA-Z_][a-zA-Z0-9_]*';
" | awk '{print "global_direct_business_writer_nodes=" $1; if ($1 != 0) exit 1}'


echo
echo "=== API-3C / 7. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo


echo "=== API-3C OWNERSHIP / IDEMPOTENCY PREFLIGHT COMPLETE ==="
