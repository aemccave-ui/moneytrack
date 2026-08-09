#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

set -a
source /home/adm_mt/moneytrack-automation/config/n8n.env
set +a

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API3_WORK_DIR:-/tmp/api-3-production-auth-cutover}"
rm -rf "$WORK"
mkdir -p "$WORK"

MINI_ID="7TJ2xQTxLsTydXZc"
DEL_ID="MTxDel7Qp2Vn9Kc4"
REF_ID="MTxRef4Qp8Lm2Xs6"
TX_ID="UX022TxApi202608"
SUM_ID="UX022Summary202608"

UPDATED_LABELS=()
CUTOVER_COMPLETE=0

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

api_put() {
  local id="$1" body="$2" out="$3" http
  http="$(curl -sS -X PUT \
    -o "$out" -w '%{http_code}' \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary @"$body" \
    "$BASE/api/v1/workflows/$id")"
  echo "PUT workflow=$id http=$http"
  if [ "$http" != "200" ]; then
    echo "--- response ---"
    cat "$out" || true
    echo
    echo "----------------"
    return 1
  fi
}

build_api_safe_body() {
  local src="$1" dst="$2"
  jq '{
        name,
        nodes,
        connections,
        settings: {
          executionOrder: (.settings.executionOrder // "v1")
        }
      }' "$src" > "$dst"
}

rollback() {
  local rc="$1"
  if [ "$CUTOVER_COMPLETE" -eq 1 ] || [ "${#UPDATED_LABELS[@]}" -eq 0 ]; then
    return "$rc"
  fi

  echo
  echo "=== API-3B AUTOMATIC ROLLBACK ==="
  local i label id
  for (( i=${#UPDATED_LABELS[@]}-1; i>=0; i-- )); do
    label="${UPDATED_LABELS[$i]}"
    id="$(id_for "$label")"
    echo "rollback label=$label workflow=$id"
    if api_put "$id" "$WORK/$label.rollback.put.json" "$WORK/$label.rollback.response.json"; then
      api_get "$id" "$WORK/$label.rollback.after.json"
      jq '{id,name,active,versionId,activeVersionId,versionCounter}' "$WORK/$label.rollback.after.json"
    else
      echo "ROLLBACK FAILED label=$label workflow=$id"
    fi
  done
  echo "API-3B rollback attempted for all workflows changed in this run"
  return "$rc"
}
trap 'rc=$?; rollback "$rc"; exit "$rc"' EXIT


echo "=== API-3B / 1. TOOLING COMPILE ==="
python3 -m py_compile \
  scripts/api-3-transform-auth-cutover.py \
  scripts/api-3-verify-auth-cutover.py
echo "python_compile=PASS"

python3 - <<'PY'
from pathlib import Path
p = Path('scripts/api-3-telegram-initdata-verifier.fragment.js')
s = p.read_text(encoding='utf-8')
for marker in (
    'MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION=api3b-v1',
    'AUTH_DATE_EXPIRED',
    'AUTH_DATE_IN_FUTURE',
    'timingSafeEqual',
    'Date.now()',
):
    if marker not in s:
        raise SystemExit(f'fragment marker missing: {marker}')
print('canonical_fragment_gate=PASS')
PY


echo
echo "=== API-3B / 2. FRESH PRODUCTION SNAPSHOT ==="
for label in miniapp delete reference transactions summary; do
  id="$(id_for "$label")"
  api_get "$id" "$WORK/$label.before.json"
  jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/$label.before.json"
  jq -e '.active == true and .versionId == .activeVersionId' "$WORK/$label.before.json" >/dev/null
done
echo "fresh_identity_gate=PASS"


echo
echo "=== API-3B / 3. BUILD + VERIFY CANDIDATES ==="
python3 scripts/api-3-transform-auth-cutover.py \
  --miniapp "$WORK/miniapp.before.json" \
  --delete "$WORK/delete.before.json" \
  --reference "$WORK/reference.before.json" \
  --transactions "$WORK/transactions.before.json" \
  --summary "$WORK/summary.before.json" \
  --fragment scripts/api-3-telegram-initdata-verifier.fragment.js \
  --out-dir "$WORK"

python3 scripts/api-3-verify-auth-cutover.py \
  --miniapp-before "$WORK/miniapp.before.json" --miniapp-after "$WORK/miniapp.candidate.json" \
  --delete-before "$WORK/delete.before.json" --delete-after "$WORK/delete.candidate.json" \
  --reference-before "$WORK/reference.before.json" --reference-after "$WORK/reference.candidate.json" \
  --transactions-before "$WORK/transactions.before.json" --transactions-after "$WORK/transactions.candidate.json" \
  --summary-before "$WORK/summary.before.json" --summary-after "$WORK/summary.candidate.json" \
  --fragment scripts/api-3-telegram-initdata-verifier.fragment.js


echo
echo "=== API-3B / 4. CANDIDATE AUTH INVENTORY ==="
python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
count = 0
exception_count = 0
for label in ('miniapp','delete','reference','transactions','summary'):
    wf = json.load(open(root / f'{label}.candidate.json', encoding='utf-8'))
    for n in wf.get('nodes', []):
        if n.get('type') != 'n8n-nodes-base.code':
            continue
        js = str((n.get('parameters') or {}).get('jsCode') or '')
        if 'MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION=api3b-v1' not in js:
            continue
        count += 1
        if 'throw new Error' in js:
            exception_count += 1
        if 'AUTH_DATE_EXPIRED' not in js or 'Date.now()' not in js or 'timingSafeEqual' not in js:
            raise SystemExit(f"{label}: incomplete canonical auth in {n.get('name')}")
        print(f"{label}: canonical_auth_node={n.get('name')}")
if count != 8:
    raise SystemExit(f'expected 8 canonical auth nodes, got {count}')
if exception_count != 0:
    raise SystemExit(f'expected 0 exception-style canonical auth nodes, got {exception_count}')
print('canonical_auth_nodes=8 PASS')
print('exception_style_auth_nodes=0 PASS')
PY


echo
echo "=== API-3B / 5. BUILD API-SAFE CUTOVER + ROLLBACK BODIES ==="
for label in miniapp delete reference transactions summary; do
  build_api_safe_body "$WORK/$label.candidate.json" "$WORK/$label.cutover.put.json"
  build_api_safe_body "$WORK/$label.before.json" "$WORK/$label.rollback.put.json"
  echo "$label settings=$(jq -c '.settings' "$WORK/$label.cutover.put.json")"
done
echo "api_safe_put_bodies=READY"


cutover_one() {
  local label="$1" id before_counter expected_version current_file current_version after_counter
  id="$(id_for "$label")"
  before_counter="$(jq -r '.versionCounter' "$WORK/$label.before.json")"
  expected_version="$(jq -r '.versionId' "$WORK/$label.before.json")"

  current_file="$WORK/$label.preput.json"
  api_get "$id" "$current_file"
  current_version="$(jq -r '.versionId' "$current_file")"
  if [ "$current_version" != "$expected_version" ]; then
    echo "$label pre-PUT drift detected expected=$expected_version current=$current_version"
    return 1
  fi
  echo "$label pre_put_drift_guard=PASS"

  echo "--- CUTOVER $label / $id ---"
  api_put "$id" "$WORK/$label.cutover.put.json" "$WORK/$label.put.response.json"
  UPDATED_LABELS+=("$label")
  api_get "$id" "$WORK/$label.after.json"
  jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/$label.after.json"
  jq -e '.active == true and .versionId == .activeVersionId' "$WORK/$label.after.json" >/dev/null
  after_counter="$(jq -r '.versionCounter' "$WORK/$label.after.json")"
  if [ "$after_counter" -ne $((before_counter + 1)) ]; then
    echo "$label version counter mismatch before=$before_counter after=$after_counter"
    return 1
  fi
  echo "$label production_cutover=PASS"
}


echo
echo "=== API-3B / 6. PRODUCTION CUTOVER ==="
cutover_one miniapp
cutover_one delete
cutover_one reference
cutover_one transactions
cutover_one summary


echo
echo "=== API-3B / 7. POST-CUTOVER EXACT ISOLATION ==="
python3 scripts/api-3-verify-auth-cutover.py \
  --miniapp-before "$WORK/miniapp.before.json" --miniapp-after "$WORK/miniapp.after.json" \
  --delete-before "$WORK/delete.before.json" --delete-after "$WORK/delete.after.json" \
  --reference-before "$WORK/reference.before.json" --reference-after "$WORK/reference.after.json" \
  --transactions-before "$WORK/transactions.before.json" --transactions-after "$WORK/transactions.after.json" \
  --summary-before "$WORK/summary.before.json" --summary-after "$WORK/summary.after.json" \
  --fragment scripts/api-3-telegram-initdata-verifier.fragment.js

python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
for label in ('miniapp','delete','reference','transactions','summary'):
    candidate = json.load(open(root / f'{label}.candidate.json', encoding='utf-8'))
    actual = json.load(open(root / f'{label}.after.json', encoding='utf-8'))
    if actual['nodes'] != candidate['nodes']:
        raise SystemExit(f'{label}: production nodes != candidate')
    if actual['connections'] != candidate['connections']:
        raise SystemExit(f'{label}: production connections != candidate')
    print(f'{label}: production_candidate_parity=PASS')
PY


echo
echo "=== API-3B / 8. MISSING-AUTH 401 CONTRACT SMOKE ==="
WEBHOOK_BASE="$BASE/webhook"

smoke_missing() {
  local label="$1" method="$2" path="$3" out="$WORK/smoke-$label.json" code
  code="$(curl -sS -X "$method" -o "$out" -w '%{http_code}' \
    -H 'Accept: application/json' \
    "$WEBHOOK_BASE/$path")"
  echo "$label missing_auth_http=$code body=$(cat "$out")"
  if [ "$code" != "401" ]; then
    echo "$label expected HTTP 401"
    return 1
  fi
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


echo
echo "=== API-3B / 9. SIGNED FRESHNESS SMOKE — TOKEN VALUE NOT PRINTED ==="
: "${MONEYTRACK_BOT_TOKEN:?MONEYTRACK_BOT_TOKEN is not set in sourced env}"

python3 - "$WORK" <<'PY'
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

root = Path(sys.argv[1])
token = os.environ['MONEYTRACK_BOT_TOKEN']
now = int(time.time())
user = json.dumps({'id': 900719925474000, 'first_name': 'API3Smoke'}, separators=(',', ':'))


def build(auth_date):
    params = {'auth_date': str(auth_date), 'user': user}
    data_check_string = '\n'.join(f'{k}={params[k]}' for k in sorted(params))
    secret = hmac.new(b'WebAppData', token.encode(), hashlib.sha256).digest()
    digest = hmac.new(secret, data_check_string.encode(), hashlib.sha256).hexdigest()
    params['hash'] = digest
    return urllib.parse.urlencode(params)

(root / 'signed-current.txt').write_text(build(now), encoding='utf-8')
(root / 'signed-expired.txt').write_text(build(now - 90000), encoding='utf-8')
(root / 'signed-future.txt').write_text(build(now + 600), encoding='utf-8')
print('signed_smoke_payloads=READY token_not_printed=PASS')
PY

signed_smoke() {
  local label="$1" payload_file="$2" expected_http="$3" expected_error="$4" out="$WORK/signed-$label.json" code payload
  payload="$(cat "$payload_file")"
  code="$(curl -sS -o "$out" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H "X-Telegram-Init-Data: $payload" \
    "$WEBHOOK_BASE/api/v1/dashboard")"
  echo "$label signed_http=$code body=$(cat "$out")"
  if [ "$code" != "$expected_http" ]; then
    echo "$label expected HTTP $expected_http"
    return 1
  fi
  if [ -n "$expected_error" ]; then
    jq -e --arg e "$expected_error" '.ok == false and .error.code == $e' "$out" >/dev/null
  fi
  echo "$label signed_contract=PASS"
}

signed_smoke current "$WORK/signed-current.txt" 404 USER_NOT_FOUND
signed_smoke expired "$WORK/signed-expired.txt" 401 AUTH_DATE_EXPIRED
signed_smoke future "$WORK/signed-future.txt" 401 AUTH_DATE_IN_FUTURE

rm -f "$WORK/signed-current.txt" "$WORK/signed-expired.txt" "$WORK/signed-future.txt"
echo "signed_smoke_payload_files_removed=PASS"


echo
echo "=== API-3B / 10. GLOBAL ZERO-WRITER ==="
docker exec postgres psql -U n8n -d n8n -P pager=off -Atc "
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
" | grep -qx '0'
echo "global_direct_business_writer_nodes=0 PASS"


echo
echo "=== API-3B / 11. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

CUTOVER_COMPLETE=1
trap - EXIT

echo
echo "=== API-3B PRODUCTION AUTH CUTOVER COMPLETE ==="
