#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
source /home/adm_mt/moneytrack-automation/config/n8n.env

BASE="${N8N_BASE_URL:-https://n8n.moneytrackapp.xyz}"
: "${N8N_API_KEY:?N8N_API_KEY is not set}"

WORK="${API3_WORK_DIR:-/tmp/api-3-auth-preflight}"
rm -rf "$WORK"
mkdir -p "$WORK"

MINI_ID="7TJ2xQTxLsTydXZc"
DEL_ID="MTxDel7Qp2Vn9Kc4"
REF_ID="MTxRef4Qp8Lm2Xs6"
TX_ID="UX022TxApi202608"
SUM_ID="UX022Summary202608"

api_get() {
  local id="$1" out="$2"
  curl -fsS \
    -H "X-N8N-API-KEY: $N8N_API_KEY" \
    "$BASE/api/v1/workflows/$id" > "$out"
}

echo "=== API-3A / 1. FRESH ACTIVE WORKFLOW SNAPSHOT ==="
for spec in \
  "miniapp:$MINI_ID" \
  "delete:$DEL_ID" \
  "reference:$REF_ID" \
  "transactions:$TX_ID" \
  "summary:$SUM_ID"
do
  label="${spec%%:*}"
  id="${spec#*:}"
  api_get "$id" "$WORK/$label.json"
  jq '{id,name,active,versionId,activeVersionId,versionCounter,nodes:(.nodes|length)}' "$WORK/$label.json"
  jq -e '.active == true and .versionId == .activeVersionId' "$WORK/$label.json" >/dev/null
done
echo "fresh_identity_gate=PASS"


echo
echo "=== API-3A / 2. AUTH + ENDPOINT INVENTORY ==="
python3 - "$WORK" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
labels = ("miniapp", "delete", "reference", "transactions", "summary")
expected = {
    ("GET", "api/v1/dashboard"),
    ("GET", "api/v1/accounts"),
    ("GET", "api/v1/i18n"),
    ("GET", "api/v1/me"),
    ("DELETE", "api/v1/transaction"),
    ("GET", "api/v1/transaction-reference"),
    ("GET", "api/v1/transactions"),
    ("GET", "api/v1/accounts-explorer-summary"),
}

webhooks = []
verifiers = []

for label in labels:
    wf = json.load(open(root / f"{label}.json", encoding="utf-8"))
    by_name = {n.get("name"): n for n in wf.get("nodes", [])}
    print(f"WORKFLOW label={label} id={wf.get('id')} name={wf.get('name')}")

    for node in wf.get("nodes", []):
        ntype = node.get("type", "")
        name = node.get("name", "")
        p = node.get("parameters") or {}

        if ntype == "n8n-nodes-base.webhook":
            method = str(p.get("httpMethod") or "GET").upper()
            path = str(p.get("path") or "").lstrip("/")
            auth = p.get("authentication", "none")
            webhooks.append((method, path, wf.get("id"), name, auth))
            outgoing = []
            conn = (wf.get("connections") or {}).get(name) or {}
            for lane in conn.get("main") or []:
                for edge in lane or []:
                    if edge.get("node"):
                        outgoing.append(edge.get("node"))
            print(f"  WEBHOOK {method} /{path} node={name!r} webhook_auth={auth} next={outgoing}")

        if ntype == "n8n-nodes-base.code":
            js = str(p.get("jsCode") or "")
            auth_like = (
                "WebAppData" in js
                and "createHmac" in js
                and ("receivedHash" in js or "params.hash" in js)
            )
            if not auth_like:
                continue

            fingerprint = hashlib.sha256(js.encode()).hexdigest()[:16]
            has_auth_date = bool(re.search(r"\bauth_date\b", js))
            has_now = bool(re.search(r"Date\.now\(|new Date\(|Math\.floor\(Date\.now", js))
            returns_http_error = "http_status" in js and "ok: false" in js
            throws_error = "throw new Error" in js
            derives_user = "telegram_user_id" in js and ("params.user" in js or "JSON.parse" in js)
            verifiers.append(
                (wf.get("id"), name, fingerprint, has_auth_date, has_now,
                 returns_http_error, throws_error, derives_user)
            )
            print(
                f"  AUTH node={name!r} fingerprint={fingerprint} "
                f"auth_date={has_auth_date} clock_check={has_now} "
                f"returns_http_error={returns_http_error} throws={throws_error} "
                f"derives_verified_identity={derives_user}"
            )

seen = {(m, p) for m, p, *_ in webhooks}
print()
print("=== ENDPOINT GATE ===")
for method, path in sorted(expected):
    owners = [(wid, node, auth) for m, p, wid, node, auth in webhooks if (m, p) == (method, path)]
    print(f"{method} /{path} owners={owners}")
    if len(owners) != 1:
        raise SystemExit(f"endpoint ownership failed for {(method, path)}: {owners}")

unexpected = sorted(seen - expected)
missing = sorted(expected - seen)
print(f"missing_endpoints={missing}")
print(f"unexpected_endpoints={unexpected}")
if missing or unexpected:
    raise SystemExit("active HTTP surface differs from frozen API-3 scope")
if any(path == "moneytrack-test" for _, path in seen):
    raise SystemExit("moneytrack-test reappeared")
print("active_http_surface=PASS count=8")

print()
print("=== VERIFIER DUPLICATION SUMMARY ===")
by_fp = {}
for row in verifiers:
    by_fp.setdefault(row[2], []).append((row[0], row[1]))
for fp, nodes in sorted(by_fp.items()):
    print(f"fingerprint={fp} nodes={nodes}")
print(f"auth_verifier_nodes={len(verifiers)}")
print(f"distinct_auth_fingerprints={len(by_fp)}")
print(f"auth_date_present_nodes={sum(1 for r in verifiers if r[3])}")
print(f"clock_check_present_nodes={sum(1 for r in verifiers if r[4])}")
print(f"exception_style_nodes={sum(1 for r in verifiers if r[6])}")
print(f"handled_http_error_nodes={sum(1 for r in verifiers if r[5])}")

if not verifiers:
    raise SystemExit("no Telegram InitData verifier code found")
if any(r[3] and r[4] for r in verifiers):
    print("auth_date_freshness_current=PRESENT")
else:
    print("auth_date_freshness_current=ABSENT")

print("API-3A auth inventory parser PASS")
PY


echo
echo "=== API-3A / 3. WEBHOOK-LEVEL AUTH INVENTORY ==="
docker exec postgres \
  psql -U n8n -d n8n -P pager=off -c "
select
    w.id workflow_id,
    w.name workflow_name,
    n->>'name' webhook_node,
    upper(coalesce(n->'parameters'->>'httpMethod','GET')) method,
    '/' || ltrim(coalesce(n->'parameters'->>'path',''),'/') path,
    coalesce(n->'parameters'->>'authentication','none') webhook_authentication
from workflow_entity w
cross join lateral jsonb_array_elements(w.nodes::jsonb) n
where w.active=true
  and n->>'type'='n8n-nodes-base.webhook'
order by path,method;
"


echo
echo "=== API-3A / 4. BOT TOKEN PRESENCE — VALUE NOT PRINTED ==="
if docker exec n8n sh -lc 'test -n "${MONEYTRACK_BOT_TOKEN:-}"'; then
  echo "moneytrack_bot_token_present=PASS"
else
  echo "moneytrack_bot_token_present=FAIL"
  exit 1
fi


echo
echo "=== API-3A / 5. GLOBAL ZERO-WRITER REASSERTION ==="
docker exec postgres \
  psql -U n8n -d n8n -At -c "
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
echo "=== API-3A / 6. N8N HEALTH ==="
curl -fsS --max-time 5 http://127.0.0.1:5678/healthz
echo

echo "=== API-3A AUTH PREFLIGHT COMPLETE ==="
