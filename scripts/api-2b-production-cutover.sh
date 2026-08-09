#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
source /home/adm_mt/moneytrack-automation/config/n8n.env

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API2B_WORK_DIR:-/tmp/api-2b-production-cutover}"
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
  echo "=== API-2B AUTOMATIC ROLLBACK ==="
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
  echo "API-2B rollback attempted for all workflows changed in this run"
  return "$rc"
}
trap 'rc=$?; rollback "$rc"; exit "$rc"' EXIT


echo "=== API-2B / 1. TOOLING COMPILE ==="
python3 -m py_compile \
  scripts/api-2b-contract-preflight.py \
  scripts/api-2b-transform-contract.py \
  scripts/api-2b-verify-contract-cutover.py
echo "python_compile=PASS"


echo
echo "=== API-2B / 2. FRESH PRODUCTION SNAPSHOT ==="
for label in miniapp delete reference transactions summary; do
  id="$(id_for "$label")"
  api_get "$id" "$WORK/$label.before.json"
  jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/$label.before.json"
  jq -e '.active == true and .versionId == .activeVersionId' "$WORK/$label.before.json" >/dev/null
done
echo "fresh_identity_gate=PASS"


echo
echo "=== API-2B / 3. PREFLIGHT OWNERSHIP + CONTRACT SNAPSHOT ==="
python3 scripts/api-2b-contract-preflight.py \
  "$WORK/miniapp.before.json" \
  "$WORK/delete.before.json" \
  "$WORK/reference.before.json" \
  "$WORK/transactions.before.json" \
  "$WORK/summary.before.json" \
  > "$WORK/preflight.txt"
tail -n 12 "$WORK/preflight.txt"


echo
echo "=== API-2B / 4. BUILD CANDIDATES ==="
python3 scripts/api-2b-transform-contract.py \
  --miniapp "$WORK/miniapp.before.json" \
  --delete "$WORK/delete.before.json" \
  --reference "$WORK/reference.before.json" \
  --transactions "$WORK/transactions.before.json" \
  --summary "$WORK/summary.before.json" \
  --out-dir "$WORK"

python3 scripts/api-2b-verify-contract-cutover.py \
  --miniapp-before "$WORK/miniapp.before.json" --miniapp-after "$WORK/miniapp.candidate.json" \
  --delete-before "$WORK/delete.before.json" --delete-after "$WORK/delete.candidate.json" \
  --reference-before "$WORK/reference.before.json" --reference-after "$WORK/reference.candidate.json" \
  --transactions-before "$WORK/transactions.before.json" --transactions-after "$WORK/transactions.candidate.json" \
  --summary-before "$WORK/summary.before.json" --summary-after "$WORK/summary.candidate.json"


echo
echo "=== API-2B / 5. BUILD API-SAFE CUTOVER + ROLLBACK BODIES ==="
for label in miniapp delete reference transactions summary; do
  build_api_safe_body "$WORK/$label.candidate.json" "$WORK/$label.cutover.put.json"
  build_api_safe_body "$WORK/$label.before.json" "$WORK/$label.rollback.put.json"
  echo "$label settings=$(jq -c '.settings' "$WORK/$label.cutover.put.json")"
done
echo "api_safe_put_bodies=READY"


cutover_one() {
  local label="$1" id before_counter after_counter
  id="$(id_for "$label")"
  before_counter="$(jq -r '.versionCounter' "$WORK/$label.before.json")"

  echo
  echo "--- CUTOVER $label / $id ---"
  api_put "$id" "$WORK/$label.cutover.put.json" "$WORK/$label.put.response.json"
  UPDATED_LABELS+=("$label")
  api_get "$id" "$WORK/$label.after.json"
  jq '{id,name,active,versionId,activeVersionId,versionCounter}' "$WORK/$label.after.json"
  jq -e '.active == true and .versionId == .activeVersionId' "$WORK/$label.after.json" >/dev/null
  after_counter="$(jq -r '.versionCounter' "$WORK/$label.after.json")"
  if [ "$after_counter" -ne $((before_counter + 1)) ]; then
    echo "$label version counter mismatch before=$before_counter after=$after_counter"
    return 1
  fi
  echo "$label production_cutover=PASS"
}


echo
echo "=== API-2B / 6. PRODUCTION CUTOVER ==="
cutover_one miniapp
cutover_one delete
cutover_one reference
cutover_one transactions
cutover_one summary


echo
echo "=== API-2B / 7. POST-CUTOVER STRUCTURAL ISOLATION ==="
python3 scripts/api-2b-verify-contract-cutover.py \
  --miniapp-before "$WORK/miniapp.before.json" --miniapp-after "$WORK/miniapp.after.json" \
  --delete-before "$WORK/delete.before.json" --delete-after "$WORK/delete.after.json" \
  --reference-before "$WORK/reference.before.json" --reference-after "$WORK/reference.after.json" \
  --transactions-before "$WORK/transactions.before.json" --transactions-after "$WORK/transactions.after.json" \
  --summary-before "$WORK/summary.before.json" --summary-after "$WORK/summary.after.json"

python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
for label in ("miniapp", "delete", "reference", "transactions", "summary"):
    candidate = json.load(open(root / f"{label}.candidate.json", encoding="utf-8"))
    actual = json.load(open(root / f"{label}.after.json", encoding="utf-8"))
    if actual["nodes"] != candidate["nodes"]:
        raise SystemExit(f"{label}: production nodes != candidate")
    if actual["connections"] != candidate["connections"]:
        raise SystemExit(f"{label}: production connections != candidate")
    print(f"{label}: production_candidate_parity=PASS")
PY


echo
echo "=== API-2B / 8. CANONICAL RESPONSE INVENTORY ==="
python3 - "$WORK" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
interesting = {
    "miniapp": {"Format Dashboard Response", "Format Accounts Response"},
    "delete": {"Format Delete Response"},
    "reference": {"Format Transaction Reference"},
    "transactions": {"Respond Transactions", "Respond Transactions Error"},
    "summary": {"Respond Explorer Summary", "Respond Explorer Summary Error"},
}
for label, names in interesting.items():
    wf = json.load(open(root / f"{label}.after.json", encoding="utf-8"))
    print(f"WORKFLOW {label} {wf['id']}")
    for n in wf["nodes"]:
        if n["name"] not in names and n.get("type") != "n8n-nodes-base.respondToWebhook":
            continue
        if n["name"] in names or any(
            n["name"] == edge.get("node")
            for source in names
            for lane in ((wf.get("connections", {}).get(source, {}) or {}).get("main", []) or [])
            for edge in (lane or [])
        ):
            p = n.get("parameters", {})
            if n.get("type") == "n8n-nodes-base.code":
                js = " ".join(str(p.get("jsCode", "")).split())
                print(f"  CODE {n['name']}: canonical_ok={'ok: true' in js} canonical_error={'error: { code:' in js}")
            elif n.get("type") == "n8n-nodes-base.respondToWebhook":
                print(f"  RESPOND {n['name']}: respondWith={p.get('respondWith')} responseCode={(p.get('options') or {}).get('responseCode')} body={p.get('responseBody')}")
PY


echo
echo "=== API-2B / 9. GLOBAL ZERO-WRITER ==="
docker exec postgres psql -U n8n -d n8n -P pager=off -c "
with nodes as (
    select w.id workflow_id, w.name workflow_name, n->>'name' node_name,
           coalesce(n->'parameters'->>'query','') query_text
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active=true
), mutations as (
    select workflow_id,workflow_name,node_name,
           regexp_matches(query_text,
             '(?i)(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\\.([a-zA-Z_][a-zA-Z0-9_]*)','g') m
    from nodes
)
select workflow_id,workflow_name,node_name,lower(m[1]) operation,lower(m[2]) table_name
from mutations order by workflow_name,node_name,table_name;
"

docker exec postgres psql -U n8n -d n8n -P pager=off -c "
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
echo "=== API-2B / 10. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

CUTOVER_COMPLETE=1
trap - EXIT

echo
echo "=== API-2B PRODUCTION CUTOVER COMPLETE ==="
