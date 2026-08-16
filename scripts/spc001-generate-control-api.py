#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / "scripts/api-3-telegram-initdata-verifier.fragment.js").read_text(encoding="utf-8").strip()
NS = uuid.UUID("1ca0e637-8ba6-4fe2-bb97-c35892862371")

ROUTES = [
    ("GET", "api/v1/spaces", "normal"),
    ("POST", "api/v1/spaces", "normal"),
    ("PATCH", "api/v1/spaces", "normal"),
    ("POST", "api/v1/spaces/archive", "normal"),
    ("POST", "api/v1/spaces/active", "normal"),
    ("POST", "api/v1/spaces/default-capture", "normal"),
    ("POST", "api/v1/spaces/invite", "invite_create"),
    ("POST", "api/v1/spaces/invite/revoke", "normal"),
    ("POST", "api/v1/spaces/invite/accept", "invite_accept"),
    ("GET", "api/v1/spaces/members", "normal"),
    ("POST", "api/v1/spaces/members/remove", "normal"),
    ("GET", "api/v1/capture/projections", "normal"),
    ("POST", "api/v1/capture/projections", "normal"),
]


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def node(node_type: str, name: str, parameters: dict, x: int, y: int, version=2) -> dict:
    return {
        "parameters": parameters,
        "type": node_type,
        "typeVersion": version,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def webhook(name: str, path: str, method: str, y: int) -> dict:
    result = node(
        "n8n-nodes-base.webhook",
        name,
        {"path": path, "httpMethod": method, "responseMode": "responseNode", "options": {}},
        -720,
        y,
        2.1,
    )
    result["webhookId"] = uid("webhook:" + name)
    return result


def if_node(name: str, y: int) -> dict:
    return node(
        "n8n-nodes-base.if",
        name,
        {
            "conditions": {
                "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
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
        -280,
        y,
        2.2,
    )


def postgres(name: str, query: str, y: int, credential_id: str, credential_name: str) -> dict:
    result = node(
        "n8n-nodes-base.postgres",
        name,
        {"operation": "executeQuery", "query": query, "options": {}},
        -40,
        y - 70,
        2.6,
    )
    result["credentials"] = {"postgres": {"id": credential_id, "name": credential_name}}
    result["onError"] = "continueRegularOutput"
    return result


def respond(name: str, y: int) -> dict:
    return node(
        "n8n-nodes-base.respondToWebhook",
        name,
        {
            "respondWith": "json",
            "responseBody": "={{ JSON.stringify($json.ok === false ? {ok:false,error:$json.error} : {ok:true,data:$json.data}) }}",
            "options": {"responseCode": "={{ $json.http_status || 200 }}"},
        },
        450,
        y,
        1.4,
    )


VERIFY_BASE = f'''const crypto = require("crypto");
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
const out={{
  ok:true,
  telegram_user_id:auth.telegram_user_id,
  username:auth.user?.username||null,
  first_name:auth.user?.first_name||null,
  telegram_language_code:auth.user?.language_code||null,
  query,
  body,
  invite_token_hash:null,
  invite_expires_at:null,
  invite_url:null
}};
'''

VERIFY_NORMAL = VERIFY_BASE + "return [{json:out}];"

VERIFY_INVITE_CREATE = VERIFY_BASE + r'''
const ttl=Number($env.MONEYTRACK_INVITE_TTL_SECONDS||0);
if(!Number.isInteger(ttl)||ttl<300||ttl>2592000) return [{json:{ok:false,http_status:503,error:{code:"INVITE_SERVER_NOT_READY"}}}];
const base=String($env.MONEYTRACK_INVITE_BASE_URL||"").trim();
if(!/^https:\/\/t\.me\//i.test(base)) return [{json:{ok:false,http_status:503,error:{code:"INVITE_SERVER_NOT_READY"}}}];
const token=crypto.randomBytes(32).toString("base64url");
out.invite_token_hash=crypto.createHash("sha256").update(token,"utf8").digest("hex");
out.invite_expires_at=new Date(Date.now()+ttl*1000).toISOString();
const separator=base.includes("?")?"&":"?";
out.invite_url=`${base}${separator}startapp=${encodeURIComponent(`invite_${token}`)}`;
return [{json:out}];'''

VERIFY_INVITE_ACCEPT = VERIFY_BASE + r'''
let token=String(body.invite_token||"").trim();
if(token.startsWith("invite_")) token=token.slice(7);
if(!/^[A-Za-z0-9_-]{32,256}$/.test(token)) return [{json:{ok:false,http_status:400,error:{code:"INVITE_TOKEN_INVALID"}}}];
out.invite_token_hash=crypto.createHash("sha256").update(token,"utf8").digest("hex");
return [{json:out}];'''

FORMAT = r'''const row=$input.first().json||{};
if(row.error){
  const raw=String(row.error.message||row.error||"DOMAIN_ERROR");
  const match=raw.match(/\b([A-Z][A-Z0-9_]+)\b/);
  const code=match?match[1]:"DOMAIN_ERROR";
  const forbidden=code.includes("NOT_MEMBER")||code.includes("OWNER_")||code.includes("NOT_ALLOWED");
  return [{json:{ok:false,http_status:forbidden?403:400,error:{code}}}];
}
return [{json:{ok:true,http_status:200,data:row.data??{}}}];'''


def invite_create_format(verifier_name: str) -> str:
    return f'''const row=$input.first().json||{{}};
if(row.error){{
  const raw=String(row.error.message||row.error||"INVITE_CREATE_FAILED");
  const match=raw.match(/\\b([A-Z][A-Z0-9_]+)\\b/);
  return [{{json:{{ok:false,http_status:400,error:{{code:match?match[1]:"INVITE_CREATE_FAILED"}}}}}}];
}}
const prepared=$({json.dumps(verifier_name)}).first().json||{{}};
return [{{json:{{ok:true,http_status:200,data:{{...(row.data||{{}}),invite_url:prepared.invite_url}}}}}}];'''


def sql_query(method: str, path: str) -> str:
    return f"""select moneytrack.spc001_control_api_dispatch_v1(
  {{{{ $json.telegram_user_id }}}}::bigint,
  {{{{ $json.username ? "'" + $json.username.replaceAll("'", "''") + "'" : "NULL" }}}}::text,
  {{{{ $json.first_name ? "'" + $json.first_name.replaceAll("'", "''") + "'" : "NULL" }}}}::text,
  {{{{ $json.telegram_language_code ? "'" + $json.telegram_language_code.replaceAll("'", "''") + "'" : "NULL" }}}}::text,
  '{method}'::text,
  '{path}'::text,
  '{{{{ JSON.stringify($json.query || {{}}).replaceAll("'", "''") }}}}'::jsonb,
  '{{{{ JSON.stringify($json.body || {{}}).replaceAll("'", "''") }}}}'::jsonb,
  {{{{ $json.invite_token_hash ? "'" + $json.invite_token_hash + "'" : "NULL" }}}}::text,
  {{{{ $json.invite_expires_at ? "'" + $json.invite_expires_at + "'" : "NULL" }}}}::timestamptz
) as data;"""


def build(credential_id: str, credential_name: str) -> dict:
    workflow_id = "SPC001ControlApi202608"
    nodes: list[dict] = []
    connections: dict[str, dict] = {}

    for index, (method, path, mode) in enumerate(ROUTES):
        y = index * 260
        label = f"SPC001 {method} {path}"
        wh = label + " Webhook"
        vr = label + " Telegram Verify"
        gate = label + " Auth OK"
        db = label + " Backend"
        fm = label + " Format"
        rp = label + " Respond"

        verify_js = VERIFY_NORMAL
        format_js = FORMAT
        if mode == "invite_create":
            verify_js = VERIFY_INVITE_CREATE
            format_js = invite_create_format(vr)
        elif mode == "invite_accept":
            verify_js = VERIFY_INVITE_ACCEPT

        nodes.extend([
            webhook(wh, path, method, y),
            node("n8n-nodes-base.code", vr, {"jsCode": verify_js}, -500, y, 2),
            if_node(gate, y),
            postgres(db, sql_query(method, path), y, credential_id, credential_name),
            node("n8n-nodes-base.code", fm, {"jsCode": format_js}, 200, y - 70, 2),
            respond(rp, y),
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
        "name": "MoneyTrack SPC-001 Space Control API",
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
    for method, path, mode in ROUTES:
        print(f"SPC_CONTROL {method} /{path} mode={mode}")


if __name__ == "__main__":
    main()
