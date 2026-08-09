#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
source /home/adm_mt/moneytrack-automation/config/n8n.env

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API2C_WORK_DIR:-/tmp/api-2c-production-remove-test-ingress}"
rm -rf "$WORK"
mkdir -p "$WORK"

MAIN_ID="DER2Lc3dT2afyQhy"
MINI_ID="7TJ2xQTxLsTydXZc"
UPDATED=0
CUTOVER_COMPLETE=0

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
  if [ "$CUTOVER_COMPLETE" -eq 1 ] || [ "$UPDATED" -eq 0 ]; then
    return "$rc"
  fi

  echo
  echo "=== API-2C AUTOMATIC ROLLBACK ==="
  if api_put "$MAIN_ID" "$WORK/main.rollback.put.json" "$WORK/main.rollback.response.json"; then
    api_get "$MAIN_ID" "$WORK/main.rollback.after.json"
    jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' \
      "$WORK/main.rollback.after.json"
    echo "rollback=ATTEMPTED_SUCCESS"
  else
    echo "rollback=FAILED"
  fi
  return "$rc"
}
trap 'rc=$?; rollback "$rc"; exit "$rc"' EXIT


echo "=== API-2C / 1. TOOLING COMPILE ==="
python3 -m py_compile \
  scripts/api-2c-transform-remove-test-ingress.py \
  scripts/api-2c-verify-remove-test-ingress.py
echo "python_compile=PASS"


echo
echo "=== API-2C / 2. FRESH PRODUCTION SNAPSHOT ==="
api_get "$MAIN_ID" "$WORK/main.before.json"
api_get "$MINI_ID" "$WORK/miniapp.before.json"

jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/main.before.json"
jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/miniapp.before.json"

jq -e '.active == true and .versionId == .activeVersionId' "$WORK/main.before.json" >/dev/null
jq -e '.active == true and .versionId == .activeVersionId' "$WORK/miniapp.before.json" >/dev/null

echo "fresh_identity_gate=PASS"

python3 - "$WORK/main.before.json" "$WORK/miniapp.before.json" <<'PY'
import json
import sys

main = json.load(open(sys.argv[1], encoding="utf-8"))
mini = json.load(open(sys.argv[2], encoding="utf-8"))

def hooks(wf):
    out = []
    for n in wf.get("nodes", []):
        if n.get("type") != "n8n-nodes-base.webhook":
            continue
        p = n.get("parameters") or {}
        out.append((n.get("name"), str(p.get("httpMethod") or "GET").upper(), str(p.get("path") or "").lstrip("/")))
    return out

main_target = [x for x in hooks(main) if x[2] == "moneytrack-test"]
if main_target != [("Webhook moneytrack-test", "POST", "moneytrack-test")]:
    raise SystemExit(f"unexpected moneytrack-test ownership: {main_target}")

mini_paths = {(m, p) for _, m, p in hooks(mini)}
for expected in (("GET", "api/v1/me"), ("GET", "api/v1/i18n")):
    if expected not in mini_paths:
        raise SystemExit(f"retained/deprecated endpoint missing before cutover: {expected}")

print("target_ownership_gate=PASS")
print("me_i18n_presence_before=PASS")
PY


echo
echo "=== API-2C / 3. BUILD + VERIFY CANDIDATE ==="
python3 scripts/api-2c-transform-remove-test-ingress.py \
  --before "$WORK/main.before.json" \
  --after "$WORK/main.candidate.json"

python3 scripts/api-2c-verify-remove-test-ingress.py \
  --before "$WORK/main.before.json" \
  --after "$WORK/main.candidate.json"


echo
echo "=== API-2C / 4. BUILD API-SAFE PUT + ROLLBACK ==="
build_api_safe_body "$WORK/main.candidate.json" "$WORK/main.cutover.put.json"
build_api_safe_body "$WORK/main.before.json" "$WORK/main.rollback.put.json"
echo "cutover_settings=$(jq -c '.settings' "$WORK/main.cutover.put.json")"
echo "api_safe_put_bodies=READY"


echo
echo "=== API-2C / 5. IMMEDIATE PRE-PUT DRIFT GUARD ==="
api_get "$MAIN_ID" "$WORK/main.preput.json"
python3 - "$WORK/main.before.json" "$WORK/main.preput.json" <<'PY'
import json
import sys
b = json.load(open(sys.argv[1], encoding="utf-8"))
p = json.load(open(sys.argv[2], encoding="utf-8"))
for key in ("id", "versionId", "activeVersionId", "versionCounter", "active"):
    if b.get(key) != p.get(key):
        raise SystemExit(f"pre-put identity drift: {key} before={b.get(key)!r} now={p.get(key)!r}")
if b.get("nodes") != p.get("nodes") or b.get("connections") != p.get("connections"):
    raise SystemExit("pre-put workflow graph/content drift")
print("pre_put_drift_guard=PASS")
PY


echo
echo "=== API-2C / 6. PRODUCTION REMOVE TEST INGRESS ==="
before_counter="$(jq -r '.versionCounter' "$WORK/main.before.json")"
api_put "$MAIN_ID" "$WORK/main.cutover.put.json" "$WORK/main.put.response.json"
UPDATED=1
api_get "$MAIN_ID" "$WORK/main.after.json"

jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/main.after.json"
jq -e '.active == true and .versionId == .activeVersionId' "$WORK/main.after.json" >/dev/null

after_counter="$(jq -r '.versionCounter' "$WORK/main.after.json")"
if [ "$after_counter" -ne $((before_counter + 1)) ]; then
  echo "version counter mismatch before=$before_counter after=$after_counter"
  exit 1
fi

echo "production_update=PASS"


echo
echo "=== API-2C / 7. POST-CUTOVER EXACT ISOLATION ==="
python3 scripts/api-2c-verify-remove-test-ingress.py \
  --before "$WORK/main.before.json" \
  --after "$WORK/main.after.json"

python3 - "$WORK/main.candidate.json" "$WORK/main.after.json" <<'PY'
import json
import sys
c = json.load(open(sys.argv[1], encoding="utf-8"))
a = json.load(open(sys.argv[2], encoding="utf-8"))
if c.get("nodes") != a.get("nodes"):
    raise SystemExit("production nodes != candidate")
if c.get("connections") != a.get("connections"):
    raise SystemExit("production connections != candidate")
print("production_candidate_parity=PASS")
PY


echo
echo "=== API-2C / 8. ACTIVE SURFACE RESULT ==="
docker exec postgres psql -U n8n -d n8n -P pager=off -c "
select
    w.id workflow_id,
    w.name workflow_name,
    n->>'name' node_name,
    upper(coalesce(n->'parameters'->>'httpMethod','GET')) method,
    '/' || ltrim(coalesce(n->'parameters'->>'path',''),'/') path
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and ltrim(coalesce(n->'parameters'->>'path',''),'/') in (
      'api/v1/me',
      'api/v1/i18n',
      'moneytrack-test'
  )
order by path;
"

test_count="$(docker exec postgres psql -U n8n -d n8n -Atc "
select count(*)
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and ltrim(coalesce(n->'parameters'->>'path',''),'/')='moneytrack-test';")"

me_count="$(docker exec postgres psql -U n8n -d n8n -Atc "
select count(*)
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and ltrim(coalesce(n->'parameters'->>'path',''),'/')='api/v1/me';")"

i18n_count="$(docker exec postgres psql -U n8n -d n8n -Atc "
select count(*)
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
  and ltrim(coalesce(n->'parameters'->>'path',''),'/')='api/v1/i18n';")"

if [ "$test_count" != "0" ]; then
  echo "moneytrack-test still active: count=$test_count"
  exit 1
fi
if [ "$me_count" != "1" ]; then
  echo "api/v1/me presence drift: count=$me_count"
  exit 1
fi
if [ "$i18n_count" != "1" ]; then
  echo "api/v1/i18n presence drift: count=$i18n_count"
  exit 1
fi

echo "moneytrack_test_active_count=0 PASS"
echo "api_v1_me_active_count=1 PASS"
echo "api_v1_i18n_active_count=1 PASS"


echo
echo "=== API-2C / 9. GLOBAL ZERO-WRITER ==="
writer_count="$(docker exec postgres psql -U n8n -d n8n -Atc "
with nodes as (
    select coalesce(n->'parameters'->>'query','') query_text
    from workflow_entity w
    cross join lateral jsonb_array_elements(w.nodes::jsonb) n
    where w.active=true
)
select count(*)
from nodes
where query_text ~*
  '(insert[[:space:][:cntrl:]]+into|update|delete[[:space:][:cntrl:]]+from)[[:space:][:cntrl:]]+moneytrack\\.[a-zA-Z_][a-zA-Z0-9_]*';")"

if [ "$writer_count" != "0" ]; then
  echo "global direct business writer regression: $writer_count"
  exit 1
fi
echo "global_direct_business_writer_nodes=0 PASS"


echo
echo "=== API-2C / 10. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

CUTOVER_COMPLETE=1
trap - EXIT

echo
echo "=== API-2C PRODUCTION REMOVAL COMPLETE ==="
