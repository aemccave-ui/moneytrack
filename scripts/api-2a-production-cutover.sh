#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

source /home/adm_mt/moneytrack-automation/config/n8n.env

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API2A_WORK_DIR:-/tmp/api-2a-production-cutover}"
rm -rf "$WORK"
mkdir -p "$WORK"

TX_ID="UX022TxApi202608"
SUM_ID="UX022Summary202608"
REF_ID="MTxRef4Qp8Lm2Xs6"

UPDATED_LABELS=()
CUTOVER_COMPLETE=0

api_get() {
  local id="$1"
  local out="$2"
  curl -fsS \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$BASE/api/v1/workflows/$id" \
    > "$out"
}

api_put() {
  local id="$1"
  local body="$2"
  local out="$3"
  local http

  http="$(
    curl -sS \
      -X PUT \
      -o "$out" \
      -w '%{http_code}' \
      -H "X-N8N-API-KEY: $N8N_API_KEY" \
      -H 'Content-Type: application/json' \
      --data-binary @"$body" \
      "$BASE/api/v1/workflows/$id"
  )"

  echo "PUT workflow=$id http=$http"
  if [ "$http" != "200" ]; then
    echo "--- response ---"
    cat "$out" || true
    echo
    echo "----------------"
    return 1
  fi
}

rollback() {
  local rc="$1"

  if [ "$CUTOVER_COMPLETE" -eq 1 ] || [ "${#UPDATED_LABELS[@]}" -eq 0 ]; then
    return "$rc"
  fi

  echo
  echo "=== API-2A AUTOMATIC ROLLBACK ==="

  local i label id body resp
  for (( i=${#UPDATED_LABELS[@]}-1; i>=0; i-- )); do
    label="${UPDATED_LABELS[$i]}"
    case "$label" in
      transactions) id="$TX_ID" ;;
      summary)      id="$SUM_ID" ;;
      reference)    id="$REF_ID" ;;
      *) echo "unknown rollback label=$label"; continue ;;
    esac

    body="$WORK/$label.rollback.put.json"
    resp="$WORK/$label.rollback.response.json"

    echo "rollback label=$label workflow=$id"
    if api_put "$id" "$body" "$resp"; then
      api_get "$id" "$WORK/$label.rollback.after.json"
      jq '{id,name,active,versionId,activeVersionId,versionCounter}' \
        "$WORK/$label.rollback.after.json"
    else
      echo "ROLLBACK FAILED for $label / $id"
    fi
  done

  echo "API-2A rollback attempted for all workflows changed in this run"
  return "$rc"
}

trap 'rc=$?; rollback "$rc"; exit "$rc"' EXIT


echo "=== API-2A / 1. FRESH PRODUCTION SNAPSHOT ==="

api_get "$TX_ID"  "$WORK/transactions.before.json"
api_get "$SUM_ID" "$WORK/summary.before.json"
api_get "$REF_ID" "$WORK/reference.before.json"

for f in \
  "$WORK/transactions.before.json" \
  "$WORK/summary.before.json" \
  "$WORK/reference.before.json"
do
  jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$f"
  jq -e '.active == true and .versionId == .activeVersionId' "$f" >/dev/null
done

echo "fresh_identity_gate=PASS"


echo
echo "=== API-2A / 2. BUILD FRESH CANDIDATES ==="

python3 scripts/api-2a-transform-read-model-cutover.py \
  --transactions "$WORK/transactions.before.json" \
  --summary "$WORK/summary.before.json" \
  --reference "$WORK/reference.before.json" \
  --out-dir "$WORK"

python3 scripts/api-2a-verify-read-model-cutover.py \
  --transactions-before "$WORK/transactions.before.json" \
  --transactions-after  "$WORK/transactions.candidate.json" \
  --summary-before      "$WORK/summary.before.json" \
  --summary-after       "$WORK/summary.candidate.json" \
  --reference-before    "$WORK/reference.before.json" \
  --reference-after     "$WORK/reference.candidate.json"


echo
echo "=== API-2A / 3. BUILD API-SAFE UPDATE + ROLLBACK BODIES ==="

for label in transactions summary reference; do
  jq '{
        name,
        nodes,
        connections,
        settings: {
          executionOrder: (.settings.executionOrder // "v1")
        }
      }' \
    "$WORK/$label.candidate.json" \
    > "$WORK/$label.cutover.put.json"

  jq '{
        name,
        nodes,
        connections,
        settings: {
          executionOrder: (.settings.executionOrder // "v1")
        }
      }' \
    "$WORK/$label.before.json" \
    > "$WORK/$label.rollback.put.json"
done

for label in transactions summary reference; do
  printf '%s cutover_settings=' "$label"
  jq -c '.settings' "$WORK/$label.cutover.put.json"
done

echo "api_safe_put_bodies=READY"


cutover_one() {
  local label="$1"
  local id="$2"
  local node_name="$3"
  local fn_name="$4"
  local before_counter
  local after_counter

  before_counter="$(jq -r '.versionCounter' "$WORK/$label.before.json")"

  echo
  echo "--- CUTOVER $label / $id ---"

  api_put \
    "$id" \
    "$WORK/$label.cutover.put.json" \
    "$WORK/$label.put.response.json"

  UPDATED_LABELS+=("$label")

  api_get "$id" "$WORK/$label.after.json"

  jq '{id,name,active,versionId,activeVersionId,versionCounter}' \
    "$WORK/$label.after.json"

  jq -e '.active == true and .versionId == .activeVersionId' \
    "$WORK/$label.after.json" >/dev/null

  after_counter="$(jq -r '.versionCounter' "$WORK/$label.after.json")"

  if [ "$after_counter" -ne $((before_counter + 1)) ]; then
    echo "version counter mismatch for $label: before=$before_counter after=$after_counter"
    return 1
  fi

  python3 - "$WORK/$label.after.json" "$node_name" "$fn_name" <<'PY'
import json
import sys

path, node_name, fn_name = sys.argv[1:]
wf = json.load(open(path, encoding="utf-8"))
node = next(n for n in wf["nodes"] if n["name"] == node_name)
query = node.get("parameters", {}).get("query", "")
if f"moneytrack.{fn_name}(" not in query:
    raise SystemExit(f"backend boundary missing: {fn_name}")
print(f"{node_name}: backend={fn_name} PASS")
PY

  echo "$label production_cutover=PASS"
}


echo
echo "=== API-2A / 4. PRODUCTION CUTOVER ==="

cutover_one \
  transactions \
  "$TX_ID" \
  "Get Account Transactions" \
  "api_transactions_read_model_v1"

cutover_one \
  summary \
  "$SUM_ID" \
  "Get Explorer Summary" \
  "api_accounts_explorer_summary_read_model_v1"

cutover_one \
  reference \
  "$REF_ID" \
  "Get Transaction Reference" \
  "api_transaction_reference_read_model_v1"


echo
echo "=== API-2A / 5. POST-CUTOVER EXACT ISOLATION ==="

python3 scripts/api-2a-verify-read-model-cutover.py \
  --transactions-before "$WORK/transactions.before.json" \
  --transactions-after  "$WORK/transactions.after.json" \
  --summary-before      "$WORK/summary.before.json" \
  --summary-after       "$WORK/summary.after.json" \
  --reference-before    "$WORK/reference.before.json" \
  --reference-after     "$WORK/reference.after.json"

python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for label in ("transactions", "summary", "reference"):
    candidate = json.load(open(root / f"{label}.candidate.json", encoding="utf-8"))
    actual = json.load(open(root / f"{label}.after.json", encoding="utf-8"))
    if actual["nodes"] != candidate["nodes"]:
        raise SystemExit(f"{label}: production nodes != candidate")
    if actual["connections"] != candidate["connections"]:
        raise SystemExit(f"{label}: production connections != candidate")
    print(f"{label}: production_candidate_parity=PASS")
PY


echo
echo "=== API-2A / 6. TARGET DATA-PATH INVENTORY ==="

docker exec postgres \
  psql -U n8n -d n8n -P pager=off -c "
select
    w.id workflow_id,
    w.name workflow_name,
    n->>'name' node_name,
    case
      when coalesce(n->'parameters'->>'query','') ~*
           'moneytrack\\.[a-zA-Z_][a-zA-Z0-9_]*_v1[[:space:]]*\\('
      then 'BACKEND_BOUNDARY'
      when coalesce(n->'parameters'->>'query','') ~* '\\mselect\\M'
       and coalesce(n->'parameters'->>'query','') ~* 'moneytrack\\.'
      then 'DIRECT_READ_SQL'
      else 'OTHER'
    end classification,
    left(
      regexp_replace(
        coalesce(n->'parameters'->>'query',''),
        '[[:space:][:cntrl:]]+',
        ' ',
        'g'
      ),
      160
    ) query_preview
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and (
       (w.id='$TX_ID'  and n->>'name'='Get Account Transactions')
    or (w.id='$SUM_ID' and n->>'name'='Get Explorer Summary')
    or (w.id='$REF_ID' and n->>'name'='Get Transaction Reference')
  )
order by w.id;
"


echo
echo "=== API-2A / 7. GLOBAL ZERO-WRITER ==="

docker exec postgres \
  psql -U n8n -d n8n -P pager=off -c "
with nodes as (
    select
        w.id workflow_id,
        w.name workflow_name,
        n->>'name' node_name,
        coalesce(n->'parameters'->>'query','') query_text
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active=true
), mutations as (
    select
        workflow_id,
        workflow_name,
        node_name,
        regexp_matches(
          query_text,
          '(?i)(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\\.([a-zA-Z_][a-zA-Z0-9_]*)',
          'g'
        ) m
    from nodes
)
select
    workflow_id,
    workflow_name,
    node_name,
    lower(m[1]) operation,
    lower(m[2]) table_name
from mutations
order by workflow_name,node_name,table_name;
"

docker exec postgres \
  psql -U n8n -d n8n -P pager=off -c "
with nodes as (
    select coalesce(n->'parameters'->>'query','') query_text
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active=true
)
select count(*) as global_direct_business_writer_nodes
from nodes
where query_text ~*
  '(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\\.[a-zA-Z_][a-zA-Z0-9_]*';
"


echo
echo "=== API-2A / 8. N8N HEALTH ==="

curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

CUTOVER_COMPLETE=1
trap - EXIT

echo
echo "=== API-2A PRODUCTION CUTOVER COMPLETE ==="