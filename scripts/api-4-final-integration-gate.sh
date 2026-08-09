#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

set -a
source /home/adm_mt/moneytrack-automation/config/n8n.env
set +a

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API4_WORK_DIR:-/tmp/api-4-final-integration-gate}"
rm -rf "$WORK"
mkdir -p "$WORK"

MINI_ID="7TJ2xQTxLsTydXZc"
DEL_ID="MTxDel7Qp2Vn9Kc4"
REF_ID="MTxRef4Qp8Lm2Xs6"
TX_ID="UX022TxApi202608"
SUM_ID="UX022Summary202608"

id_for() {
  case "$1" in
    miniapp) echo "$MINI_ID" ;;
    delete) echo "$DEL_ID" ;;
    reference) echo "$REF_ID" ;;
    transactions) echo "$TX_ID" ;;
    summary) echo "$SUM_ID" ;;
    *) return 1 ;;
  esac
}

api_get() {
  local id="$1" out="$2"
  curl -fsS \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$BASE/api/v1/workflows/$id" > "$out"
}


echo "=== API-4 / 1. FRESH ACTIVE WORKFLOW SNAPSHOT ==="
for label in miniapp delete reference transactions summary; do
  id="$(id_for "$label")"
  api_get "$id" "$WORK/$label.json"
  jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/$label.json"
  jq -e '.active == true and .versionId == .activeVersionId' "$WORK/$label.json" >/dev/null
done
echo "active_identity_gate=PASS"


echo
echo "=== API-4 / 2. EXACT ACTIVE HTTP SURFACE ==="
python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    ('GET', '/api/v1/dashboard'),
    ('GET', '/api/v1/accounts'),
    ('GET', '/api/v1/i18n'),
    ('GET', '/api/v1/me'),
    ('DELETE', '/api/v1/transaction'),
    ('GET', '/api/v1/transaction-reference'),
    ('GET', '/api/v1/transactions'),
    ('GET', '/api/v1/accounts-explorer-summary'),
}
owners = {}
for label in ('miniapp','delete','reference','transactions','summary'):
    wf = json.load(open(root / f'{label}.json', encoding='utf-8'))
    for n in wf.get('nodes', []):
        if n.get('type') != 'n8n-nodes-base.webhook':
            continue
        p = n.get('parameters') or {}
        method = str(p.get('httpMethod') or 'GET').upper()
        path = '/' + str(p.get('path') or '').lstrip('/')
        key = (method, path)
        owners.setdefault(key, []).append((wf.get('id'), n.get('name')))

actual = set(owners)
for key in sorted(actual):
    print(f'{key[0]} {key[1]} owners={owners[key]}')
missing = sorted(expected - actual)
unexpected = sorted(actual - expected)
duplicates = {k:v for k,v in owners.items() if len(v) != 1}
print(f'missing_endpoints={missing}')
print(f'unexpected_endpoints={unexpected}')
print(f'duplicate_owners={duplicates}')
if missing or unexpected or duplicates:
    raise SystemExit('active HTTP surface mismatch')
if any(path == '/moneytrack-test' for _, path in actual):
    raise SystemExit('/moneytrack-test reappeared')
print('active_http_surface=PASS count=8')
print('moneytrack_test_absent=PASS')
PY


echo
echo "=== API-4 / 3. CANONICAL AUTH REASSERTION ==="
python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected_nodes = {
    'miniapp': {
        'Verify Telegram InitData me',
        'Verify Telegram InitData dashboard',
        'Verify Telegram InitData accounts',
        'Verify Telegram InitData i18n',
    },
    'delete': {'Verify Telegram InitData delete'},
    'reference': {'Verify Telegram InitData reference'},
    'transactions': {'Validate Transactions Request'},
    'summary': {'Validate Explorer Summary Request'},
}
count = 0
for label, names in expected_nodes.items():
    wf = json.load(open(root / f'{label}.json', encoding='utf-8'))
    found = set()
    for n in wf.get('nodes', []):
        if n.get('name') not in names:
            continue
        js = str((n.get('parameters') or {}).get('jsCode') or '')
        if 'MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION=api3b-v1' not in js:
            raise SystemExit(f'{label}: canonical auth marker missing in {n.get("name")}')
        if 'AUTH_DATE_EXPIRED' not in js or 'AUTH_DATE_IN_FUTURE' not in js or 'timingSafeEqual' not in js:
            raise SystemExit(f'{label}: canonical freshness/HMAC marker incomplete in {n.get("name")}')
        if 'throw new Error' in js:
            raise SystemExit(f'{label}: exception-style canonical auth in {n.get("name")}')
        found.add(n.get('name'))
        count += 1
        print(f'{label}: canonical_auth_node={n.get("name")}')
    if found != names:
        raise SystemExit(f'{label}: auth node set mismatch expected={sorted(names)} found={sorted(found)}')
if count != 8:
    raise SystemExit(f'expected 8 canonical auth nodes, got {count}')
print('canonical_auth_nodes=8 PASS')
print('exception_style_canonical_auth_nodes=0 PASS')
PY


echo
echo "=== API-4 / 4. BACKEND BOUNDARY CALL INVENTORY ==="
python3 - "$WORK" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
expected = {
    'miniapp': {
        'moneytrack.finance_dashboard_read_model_v1': 1,
        'moneytrack.finance_accounts_read_model_v1': 1,
    },
    'delete': {'moneytrack.finance_delete_transaction_v1': 1},
    'reference': {'moneytrack.api_transaction_reference_read_model_v1': 1},
    'transactions': {'moneytrack.api_transactions_read_model_v1': 1},
    'summary': {'moneytrack.api_accounts_explorer_summary_read_model_v1': 1},
}
mutation_re = re.compile(r'(?is)\b(insert\s+into|update|delete\s+from)\s+moneytrack\.[A-Za-z_][A-Za-z0-9_]*')
for label in ('miniapp','delete','reference','transactions','summary'):
    wf = json.load(open(root / f'{label}.json', encoding='utf-8'))
    all_queries = []
    direct_mutations = []
    for n in wf.get('nodes', []):
        q = str((n.get('parameters') or {}).get('query') or '')
        if not q:
            continue
        all_queries.append((n.get('name'), q))
        if mutation_re.search(q):
            direct_mutations.append(n.get('name'))
    if direct_mutations:
        raise SystemExit(f'{label}: direct business mutations found {direct_mutations}')
    joined = '\n'.join(q for _, q in all_queries)
    for fn, expected_count in expected[label].items():
        count = joined.count(fn)
        print(f'{label}: boundary={fn} count={count}')
        if count != expected_count:
            raise SystemExit(f'{label}: boundary count mismatch for {fn}: {count}')
print('backend_boundary_calls=PASS')
print('workflow_direct_business_mutations=0 PASS')
PY


echo
echo "=== API-4 / 5. BACKEND FUNCTION EXISTENCE ==="
docker exec moneytrack-db \
  psql -U moneytrack -d moneytrack -v ON_ERROR_STOP=1 -P pager=off -At -c "
with expected(name) as (values
  ('finance_dashboard_read_model_v1'),
  ('finance_accounts_read_model_v1'),
  ('api_transactions_read_model_v1'),
  ('api_accounts_explorer_summary_read_model_v1'),
  ('api_transaction_reference_read_model_v1'),
  ('finance_delete_transaction_v1')
), present as (
  select distinct p.proname
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='moneytrack'
)
select e.name || '=' || case when p.proname is not null then 'PASS' else 'MISSING' end
from expected e
left join present p on p.proname=e.name
order by e.name;
select 'backend_function_count=' || count(distinct p.proname)
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='moneytrack'
  and p.proname in (
    'finance_dashboard_read_model_v1',
    'finance_accounts_read_model_v1',
    'api_transactions_read_model_v1',
    'api_accounts_explorer_summary_read_model_v1',
    'api_transaction_reference_read_model_v1',
    'finance_delete_transaction_v1'
  );
" | tee "$WORK/backend-functions.txt"
grep -q '^backend_function_count=6$' "$WORK/backend-functions.txt"
if grep -q '=MISSING$' "$WORK/backend-functions.txt"; then
  echo "backend function missing"
  exit 1
fi
echo "backend_function_gate=PASS"


echo
echo "=== API-4 / 6. RETAINED MUTATION SURFACE ==="
MUTATION_COUNT="$(docker exec postgres psql -U n8n -d n8n -At -c "
select count(*)
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and upper(coalesce(n->'parameters'->>'httpMethod','GET')) in ('POST','PUT','PATCH','DELETE')
  and '/' || ltrim(coalesce(n->'parameters'->>'path',''),'/') like '/api/v1/%';
")"
echo "retained_api_mutation_endpoint_count=$MUTATION_COUNT"
[ "$MUTATION_COUNT" = "1" ]

docker exec postgres psql -U n8n -d n8n -P pager=off -c "
select w.id workflow_id,w.name workflow_name,n->>'name' node_name,
       upper(coalesce(n->'parameters'->>'httpMethod','GET')) method,
       '/' || ltrim(coalesce(n->'parameters'->>'path',''),'/') path
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and upper(coalesce(n->'parameters'->>'httpMethod','GET')) in ('POST','PUT','PATCH','DELETE')
  and '/' || ltrim(coalesce(n->'parameters'->>'path',''),'/') like '/api/v1/%';
"
echo "retained_write_surface=PASS"


echo
echo "=== API-4 / 7. MISSING-AUTH CONTRACT SMOKE ==="
WEBHOOK_BASE="$BASE/webhook"
smoke_missing() {
  local label="$1" method="$2" path="$3" out="$WORK/missing-$label.json" code
  code="$(curl -sS -X "$method" -o "$out" -w '%{http_code}' -H 'Accept: application/json' "$WEBHOOK_BASE/$path")"
  echo "$label missing_auth_http=$code body=$(cat "$out")"
  [ "$code" = "401" ]
  jq -e '.ok == false and .error.code == "INIT_DATA_MISSING"' "$out" >/dev/null
  echo "$label missing_auth_contract=PASS"
}
smoke_missing dashboard GET 'api/v1/dashboard'
smoke_missing accounts GET 'api/v1/accounts'
smoke_missing i18n GET 'api/v1/i18n'
smoke_missing me GET 'api/v1/me'
smoke_missing delete DELETE 'api/v1/transaction?id=1'
smoke_missing reference GET 'api/v1/transaction-reference'
smoke_missing transactions GET 'api/v1/transactions?account_id=1&date_from=2026-01-01&date_to=2026-01-01&include_descendants=true'
smoke_missing summary GET 'api/v1/accounts-explorer-summary?date_from=2026-01-01&date_to=2026-01-01'
echo "missing_auth_contracts=8 PASS"


echo
echo "=== API-4 / 8. FRESH SIGNED AUTH INTEGRATION SMOKE ==="
RUNTIME_BOT_TOKEN="$(docker exec n8n sh -lc 'printf %s "${MONEYTRACK_BOT_TOKEN:-}"')"
if [ -z "$RUNTIME_BOT_TOKEN" ]; then
  echo "runtime_bot_token_import=FAIL"
  exit 1
fi
export MONEYTRACK_BOT_TOKEN="$RUNTIME_BOT_TOKEN"
unset RUNTIME_BOT_TOKEN
echo "runtime_bot_token_import=PASS token_not_printed=PASS"

python3 - "$WORK/signed-current.txt" <<'PY'
import hashlib, hmac, json, os, sys, time, urllib.parse
out = sys.argv[1]
token = os.environ['MONEYTRACK_BOT_TOKEN']
params = {
    'auth_date': str(int(time.time())),
    'user': json.dumps({'id': 900719925474001, 'first_name': 'API4Smoke'}, separators=(',', ':')),
}
data = '\n'.join(f'{k}={params[k]}' for k in sorted(params))
secret = hmac.new(b'WebAppData', token.encode(), hashlib.sha256).digest()
params['hash'] = hmac.new(secret, data.encode(), hashlib.sha256).hexdigest()
open(out, 'w', encoding='utf-8').write(urllib.parse.urlencode(params))
print('signed_payload=READY token_not_printed=PASS')
PY

PAYLOAD="$(cat "$WORK/signed-current.txt")"
SIGNED_CODE="$(curl -sS -o "$WORK/signed-current.json" -w '%{http_code}' \
  -H 'Accept: application/json' \
  -H "X-Telegram-Init-Data: $PAYLOAD" \
  "$WEBHOOK_BASE/api/v1/dashboard")"
unset PAYLOAD MONEYTRACK_BOT_TOKEN
rm -f "$WORK/signed-current.txt"
echo "signed_current_http=$SIGNED_CODE body=$(cat "$WORK/signed-current.json")"
[ "$SIGNED_CODE" = "404" ]
jq -e '.ok == false and .error.code == "USER_NOT_FOUND"' "$WORK/signed-current.json" >/dev/null
echo "fresh_signed_auth_reached_backend=PASS"
echo "signed_payload_file_removed=PASS"


echo
echo "=== API-4 / 9. GLOBAL ZERO-WRITER ==="
WRITER_COUNT="$(docker exec postgres psql -U n8n -d n8n -At -c "
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
")"
echo "global_direct_business_writer_nodes=$WRITER_COUNT"
[ "$WRITER_COUNT" = "0" ]
echo "global_zero_writer=PASS"


echo
echo "=== API-4 / 10. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

echo "=== API-4 FINAL INTEGRATION GATE PASS ==="
