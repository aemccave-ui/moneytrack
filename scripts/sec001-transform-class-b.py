#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import uuid
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UNLOCK_FRAGMENT = (ROOT / "scripts/sec001-unlock-verifier.fragment.js").read_text(encoding="utf-8").strip()
NS = uuid.UUID("f5d85e3b-337a-48f7-beb4-25d2d34b6b63")

WEBHOOK = "n8n-nodes-base.webhook"
CODE = "n8n-nodes-base.code"
IF = "n8n-nodes-base.if"
POSTGRES = "n8n-nodes-base.postgres"
RESPOND = "n8n-nodes-base.respondToWebhook"

CLASS_A_PATHS = {
    "api/v1/security/status",
    "api/v1/security/pin/setup",
    "api/v1/security/pin/unlock",
    "api/v1/security/biometric/unlock",
}


def uid(workflow_id: str, value: str) -> str:
    return str(uuid.uuid5(NS, f"{workflow_id}:{value}"))


def main_edges(workflow: dict, source: str) -> list[list[dict]]:
    return copy.deepcopy(((workflow.get("connections") or {}).get(source) or {}).get("main") or [])


def node_map(workflow: dict) -> dict[str, dict]:
    return {n.get("name"): n for n in workflow.get("nodes", []) if n.get("name")}


def outgoing_names(workflow: dict, source: str) -> list[str]:
    result = []
    for lane in main_edges(workflow, source):
        for edge in lane:
            if edge.get("node"):
                result.append(edge["node"])
    return result


def find_telegram_verifier(workflow: dict, webhook_name: str) -> dict:
    nodes = node_map(workflow)
    queue = deque([webhook_name])
    seen = set()
    while queue:
        name = queue.popleft()
        if name in seen:
            continue
        seen.add(name)
        node = nodes.get(name)
        if not node:
            continue
        if node.get("type") == CODE:
            js = str((node.get("parameters") or {}).get("jsCode") or "")
            if "moneytrackVerifyTelegramInitData" in js and (
                "api3b-v1" in js or "MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION" in js
            ):
                return node
        queue.extend(outgoing_names(workflow, name))
    raise SystemExit(f"{workflow.get('id')}: no canonical Telegram verifier reachable from {webhook_name!r}")


def find_auth_gate(workflow: dict, verifier_name: str) -> dict:
    nodes = node_map(workflow)
    direct = outgoing_names(workflow, verifier_name)
    matches = [nodes[name] for name in direct if nodes.get(name, {}).get("type") == IF]
    if len(matches) != 1:
        raise SystemExit(
            f"{workflow.get('id')}: expected one IF auth gate after {verifier_name!r}, found {[n.get('name') for n in matches]}"
        )
    return matches[0]


def postgres_credential(workflow: dict, fallback_id: str, fallback_name: str) -> tuple[str, str]:
    for n in workflow.get("nodes", []):
        if n.get("type") != POSTGRES:
            continue
        cred = ((n.get("credentials") or {}).get("postgres") or {})
        if cred.get("id") and cred.get("name"):
            return str(cred["id"]), str(cred["name"])
    if fallback_id and fallback_name:
        return fallback_id, fallback_name
    raise SystemExit(f"{workflow.get('id')}: no Postgres credential found for SEC-001 unlock boundary")


def if_node(workflow_id: str, name: str, x: int, y: int) -> dict:
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
                    "id": uid(workflow_id, name + ":condition"),
                    "leftValue": "={{ $json.unlock_ok === true }}",
                    "rightValue": "",
                    "operator": {"type": "boolean", "operation": "true", "singleValue": True},
                }],
                "combinator": "and",
            },
            "options": {},
        },
        "type": IF,
        "typeVersion": 2.2,
        "position": [x, y],
        "id": uid(workflow_id, name),
        "name": name,
    }


def transform_route(workflow: dict, webhook_node: dict, fallback_cred_id: str, fallback_cred_name: str) -> None:
    workflow_id = str(workflow.get("id") or "workflow")
    webhook_name = webhook_node["name"]
    path = str((webhook_node.get("parameters") or {}).get("path") or "").lstrip("/")

    marker = f"SEC001 Unlock Prepare [{path}]"
    if marker in node_map(workflow):
        return

    verifier = find_telegram_verifier(workflow, webhook_name)
    auth_gate = find_auth_gate(workflow, verifier["name"])
    gate_edges = main_edges(workflow, auth_gate["name"])
    if not gate_edges or not gate_edges[0]:
        raise SystemExit(f"{workflow_id}: auth gate {auth_gate['name']!r} has no true branch for {path}")
    original_true = copy.deepcopy(gate_edges[0])
    false_branch = copy.deepcopy(gate_edges[1]) if len(gate_edges) > 1 else []

    cred_id, cred_name = postgres_credential(workflow, fallback_cred_id, fallback_cred_name)
    x, y = (auth_gate.get("position") or [0, 0])[:2]

    prepare_name = marker
    db_name = f"SEC001 Unlock Verify [{path}]"
    decision_name = f"SEC001 Unlock Decision [{path}]"
    if_name = f"SEC001 Unlock OK [{path}]"
    respond_name = f"SEC001 Unlock Reject [{path}]"

    webhook_ref = json.dumps(webhook_name)
    prepare_js = f'''const crypto = require("crypto");
{UNLOCK_FRAGMENT}
const request = $({webhook_ref}).first().json || {{}};
const prepared = moneytrackPrepareUnlockHash({{crypto, headers:request.headers || {{}}}});
return [{{json:{{
  ...$json,
  unlock_contract_version:prepared.unlock_contract_version,
  unlock_token_hash:prepared.unlock_token_hash
}}}}];'''

    prepare = {
        "parameters": {"jsCode": prepare_js},
        "type": CODE,
        "typeVersion": 2,
        "position": [x + 220, y - 80],
        "id": uid(workflow_id, prepare_name),
        "name": prepare_name,
    }

    query = """select * from moneytrack.security_validate_unlock_v1(
{{ $json.telegram_user_id }}::bigint,
{{ $json.unlock_token_hash && $json.unlock_token_hash !== "INVALID" ? "'" + $json.unlock_token_hash + "'" : "NULL" }}::text
);"""
    verify = {
        "parameters": {"operation": "executeQuery", "query": query, "options": {}},
        "type": POSTGRES,
        "typeVersion": 2.6,
        "position": [x + 450, y - 80],
        "id": uid(workflow_id, db_name),
        "name": db_name,
        "alwaysOutputData": True,
        "onError": "continueRegularOutput",
        "credentials": {"postgres": {"id": cred_id, "name": cred_name}},
    }

    decision_js = f'''const gate = $input.first().json || {{}};
const request = $({json.dumps(prepare_name)}).first().json || {{}};
if (gate.unlock_ok === true) {{
  const clean = {{...request}};
  delete clean.unlock_token_hash;
  delete clean.unlock_contract_version;
  return [{{json:{{...clean,unlock_ok:true,moneytrack_protection_enabled:gate.protection_enabled===true}}}}];
}}
return [{{json:{{
  ok:false,
  unlock_ok:false,
  http_status:423,
  error:{{code:gate.error_code || (gate.error ? "UNLOCK_VERIFIER_FAILED" : "UNLOCK_REQUIRED")}}
}}}}];'''
    decision = {
        "parameters": {"jsCode": decision_js},
        "type": CODE,
        "typeVersion": 2,
        "position": [x + 680, y - 80],
        "id": uid(workflow_id, decision_name),
        "name": decision_name,
    }

    gate = if_node(workflow_id, if_name, x + 900, y - 80)
    reject = {
        "parameters": {
            "respondWith": "json",
            "responseBody": "={{ JSON.stringify({ ok:false, error:$json.error || {code:'UNLOCK_REQUIRED'} }) }}",
            "options": {"responseCode": "={{ $json.http_status || 423 }}"},
        },
        "type": RESPOND,
        "typeVersion": 1.4,
        "position": [x + 1120, y + 80],
        "id": uid(workflow_id, respond_name),
        "name": respond_name,
    }

    workflow.setdefault("nodes", []).extend([prepare, verify, decision, gate, reject])
    workflow.setdefault("connections", {})[auth_gate["name"]] = {
        "main": [
            [{"node": prepare_name, "type": "main", "index": 0}],
            false_branch,
        ]
    }
    workflow["connections"][prepare_name] = {"main": [[{"node": db_name, "type": "main", "index": 0}]]}
    workflow["connections"][db_name] = {"main": [[{"node": decision_name, "type": "main", "index": 0}]]}
    workflow["connections"][decision_name] = {"main": [[{"node": if_name, "type": "main", "index": 0}]]}
    workflow["connections"][if_name] = {
        "main": [
            original_true,
            [{"node": respond_name, "type": "main", "index": 0}],
        ]
    }


def transform(workflow: dict, fallback_cred_id: str, fallback_cred_name: str) -> tuple[dict, list[str]]:
    result = copy.deepcopy(workflow)
    protected = []
    for wh in [n for n in result.get("nodes", []) if n.get("type") == WEBHOOK]:
        path = str((wh.get("parameters") or {}).get("path") or "").lstrip("/")
        if not path.startswith("api/v1/"):
            continue
        if path in CLASS_A_PATHS:
            continue
        transform_route(result, wh, fallback_cred_id, fallback_cred_name)
        protected.append(path)

    if protected:
        settings = result.setdefault("settings", {})
        settings["saveDataErrorExecution"] = "none"
        settings["saveDataSuccessExecution"] = "none"
        settings["saveExecutionProgress"] = False

    return result, protected


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--postgres-credential-id", default="tM27zg5m7tREo2ep")
    parser.add_argument("--postgres-credential-name", default="Postgres account")
    args = parser.parse_args()

    before = json.loads(args.input.read_text(encoding="utf-8"))
    after, protected = transform(before, args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(after, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"workflow={after.get('id')} protected_routes={len(protected)}")
    for path in protected:
        print(f"CLASS_B /{path}")


if __name__ == "__main__":
    main()
