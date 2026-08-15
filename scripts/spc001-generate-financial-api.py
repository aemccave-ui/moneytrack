#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / "scripts/api-3-telegram-initdata-verifier.fragment.js").read_text(encoding="utf-8").strip()
NS = uuid.UUID("d1420a6e-0af3-4bb9-83dd-1665f9ed3ddf")

ROUTES = [
    ("GET", "api/v1/dashboard"),
    ("GET", "api/v1/accounts"),
    ("POST", "api/v1/accounts"),
    ("PATCH", "api/v1/accounts"),
    ("DELETE", "api/v1/accounts"),
    ("GET", "api/v1/accounts/archived"),
    ("POST", "api/v1/accounts/copy"),
    ("POST", "api/v1/accounts/move"),
    ("POST", "api/v1/accounts/archive"),
    ("POST", "api/v1/accounts/restore"),
    ("POST", "api/v1/accounts/move-operations/preview"),
    ("POST", "api/v1/accounts/move-operations"),
    ("GET", "api/v1/transaction-reference"),
    ("PATCH", "api/v1/categories"),
    ("POST", "api/v1/transaction"),
    ("PATCH", "api/v1/transaction"),
    ("DELETE", "api/v1/transaction"),
    ("GET", "api/v1/transfer"),
    ("POST", "api/v1/transfer"),
    ("PATCH", "api/v1/transfer"),
    ("DELETE", "api/v1/transfer"),
    ("GET", "api/v1/receipt"),
    ("PATCH", "api/v1/receipt/accounting"),
    ("PATCH", "api/v1/receipt-item/category"),
    ("GET", "api/v1/transactions"),
    ("GET", "api/v1/accounts-explorer-summary"),
    ("GET", "api/v1/filter-presets"),
    ("POST", "api/v1/filter-presets"),
    ("PATCH", "api/v1/filter-presets"),
    ("DELETE", "api/v1/filter-presets"),
]


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def webhook(name: str, method: str, path: str, y: int) -> dict:
    return {
        "parameters": {
            "path": path,
            "httpMethod": method,
            "responseMode": "responseNode",
            "options": {},
        },
        "type": "n8n-nodes-base.webhook",
        "typeVersion": 2.1,
        "position": [-720, y],
        "id": uid("webhook:" + name),
        "name": name,
        "webhookId": uid("webhook-id:" + name),
    }


def code_node(name: str, js: str, x: int, y: int) -> dict:
    return {
        "parameters": {"jsCode": js},
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def if_node(name: str, x: int, y: int) -> dict:
    return {
        "parameters": {
            "conditions": {
                "options": {
                    "caseSensitive": True,
                    "leftValue": "",
                    "typeValidation": "strict",
                    "version": 2,
                },
                "conditions": [{
                    "id": uid(name + ":condition"),
                    "leftValue": "={{ $json.ok }}",
                    "rightValue": "",
                    "operator": {"type": "boolean", "operation": "true", "singleValue": True},
                }],
                "combinator": "and",
            },
            "options": {},
        },
        "type": "n8n-nodes-base.if",
        "typeVersion": 2.2,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def postgres(name: str, query: str, x: int, y: int, credential_id: str, credential_name: str) -> dict:
    return {
        "parameters": {"operation": "executeQuery", "query": query, "options": {}},
        "type": "n8n-nodes-base.postgres",
        "typeVersion": 2.6,
        "position": [x, y - 70],
        "id": uid(name),
        "name": name,
        "credentials": {"postgres": {"id": credential_id, "name": credential_name}},
        "onError": "continueRegularOutput",
    }


def respond(name: str, x: int, y: int) -> dict:
    return {
        "parameters": {
            "respondWith": "json",
            "responseBody": "={{ JSON.stringify($json.ok === false ? {ok:false,error:$json.error} : {ok:true,data:$json.data}) }}",
            "options": {"responseCode": "={{ $json.http_status || 200 }}"},
        },
        "type": "n8n-nodes-base.respondToWebhook",
        "typeVersion": 1.4,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


VERIFY = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const headers = $json.headers || {{}};
const query = $json.query || {{}};
const body = $json.body || {{}};
const initData = headers["x-telegram-init-data"] || headers["X-Telegram-Init-Data"] || query.initData || query.init_data || null;
const auth = moneytrackVerifyTelegramInitData({{
  crypto,
  initData,
  botToken:$env.MONEYTRACK_BOT_TOKEN,
  maxAgeSeconds:$env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,
  maxFutureSkewSeconds:$env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS
}});
if (!auth.ok) return [{{json:auth}}];
const rawSpace = String(headers["x-moneytrack-space-id"] || headers["X-MoneyTrack-Space-Id"] || "").trim();
if (!/^[1-9]\\d*$/.test(rawSpace)) return [{{json:{{ok:false,http_status:400,error:{{code:"SPACE_REQUIRED"}}}}}}];
const spaceId = Number(rawSpace);
if (!Number.isSafeInteger(spaceId)) return [{{json:{{ok:false,http_status:400,error:{{code:"SPACE_INVALID"}}}}}}];
return [{{json:{{
  ok:true,
  telegram_user_id:auth.telegram_user_id,
  space_id:spaceId,
  query,
  body
}}}}];'''

# n8n Postgres with onError=continueRegularOutput does not promise that the
# PostgreSQL message is always located at row.error.message. Keep the adapter
# thin but preserve an opaque MoneyTrack domain code wherever n8n nests it.
# Domain codes contain an underscore; SQLSTATEs such as P0002 therefore cannot
# win the generic fallback. Access loss remains a 403 so the MiniApp can perform
# centralized safe Space eviction instead of surfacing a generic DOMAIN_ERROR.
FORMAT = '''const row=$input.first().json||{};
function collectStrings(value,out,seen){
  if(value==null) return;
  if(typeof value==="string"){ out.push(value); return; }
  if(typeof value!=="object" || seen.has(value)) return;
  seen.add(value);
  if(Array.isArray(value)) { for(const item of value) collectStrings(item,out,seen); return; }
  for(const item of Object.values(value)) collectStrings(item,out,seen);
}
function extractDomainCode(value){
  const texts=[];
  collectStrings(value,texts,new Set());
  const joined=texts.join("\\n");
  const accessLoss=["SPACE_NOT_FOUND_OR_NOT_MEMBER","SPACE_CONTEXT_NOT_FOUND"];
  for(const code of accessLoss) if(joined.includes(code)) return code;
  const matches=joined.match(/\\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\\b/g)||[];
  return matches.find((code)=>code!=="DOMAIN_ERROR")||"DOMAIN_ERROR";
}
if(row.error){
  const code=extractDomainCode(row);
  const forbidden=new Set(["SPACE_NOT_FOUND_OR_NOT_MEMBER","SPACE_CONTEXT_NOT_FOUND","SPC001_API_ROUTE_NOT_ALLOWED","SPC001_API_METHOD_NOT_ALLOWED"]);
  return [{json:{ok:false,http_status:forbidden.has(code)?403:400,error:{code}}}];
}
return [{json:{ok:true,http_status:200,data:row.data??{}}}];'''


def sql_query(method: str, path: str) -> str:
    # Route identity is generator-owned, never request-controlled. Query/body are
    # JSON-escaped before interpolation; PostgreSQL dispatcher performs all casts,
    # validation and membership checks.
    return f"""select moneytrack.spc001_financial_api_dispatch_v1(
  {{{{ $json.telegram_user_id }}}}::bigint,
  {{{{ $json.space_id }}}}::bigint,
  '{method}'::text,
  '{path}'::text,
  '{{{{ JSON.stringify($json.query || {{}}).replaceAll("'", "''") }}}}'::jsonb,
  '{{{{ JSON.stringify($json.body || {{}}).replaceAll("'", "''") }}}}'::jsonb
) as data;"""


def build(credential_id: str, credential_name: str) -> dict:
    workflow_id = "SPC001FinancialApi202608"
    nodes: list[dict] = []
    connections: dict[str, dict] = {}

    for index, (method, path) in enumerate(ROUTES):
        y = index * 250
        label = f"SPC001 {method} {path}"
        wh = label + " Webhook"
        vr = label + " Telegram Verify"
        gate = label + " Auth OK"
        db = label + " Backend"
        fm = label + " Format"
        rp = label + " Respond"

        nodes.extend([
            webhook(wh, method, path, y),
            code_node(vr, VERIFY, -500, y),
            if_node(gate, -280, y),
            postgres(db, sql_query(method, path), -40, y - 70, credential_id, credential_name),
            code_node(fm, FORMAT, 200, y - 70),
            respond(rp, 450, y),
        ])
        connections[wh] = {"main": [[{"node": vr, "type": "main", "index": 0}]]}
        connections[vr] = {"main": [[{"node": gate, "type": "main", "index": 0}]]}
        connections[gate] = {"main": [
            [{"node": db, "type": "main", "index": 0}],
            [{"node": rp, "type": "main", "index": 0}],
        ]}
        connections[db] = {"main": [[{"node": fm, "type": "main", "index": 0}]]}
        connections[fm] = {"main": [[{"node": rp, "type": "main", "index": 0}]]}

    return {
        "id": workflow_id,
        "name": "MoneyTrack SPC-001 Financial API",
        "nodes": nodes,
        "connections": connections,
        "settings": {
            "executionOrder": "v1",
            "saveDataErrorExecution": "none",
            "saveDataSuccessExecution": "none",
            "saveExecutionProgress": False,
        },
        "active": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--postgres-credential-id", default="tM27zg5m7tREo2ep")
    parser.add_argument("--postgres-credential-name", default="Postgres account")
    args = parser.parse_args()

    workflow = build(args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"workflow={workflow['id']} routes={len(ROUTES)} nodes={len(workflow['nodes'])} path={args.output}")
    for method, path in ROUTES:
        print(f"SPC_FINANCIAL {method} /{path}")


if __name__ == "__main__":
    main()
