#!/usr/bin/env python3
import argparse
import copy
import json
import uuid
from pathlib import Path

CODE = "n8n-nodes-base.code"
IF = "n8n-nodes-base.if"
RESPOND = "n8n-nodes-base.respondToWebhook"

STANDALONE = {
    "miniapp": [
        "Verify Telegram InitData me",
        "Verify Telegram InitData dashboard",
        "Verify Telegram InitData accounts",
        "Verify Telegram InitData i18n",
    ],
    "delete": ["Verify Telegram InitData delete"],
    "reference": ["Verify Telegram InitData reference"],
}

COMBINED = {
    "transactions": "Validate Transactions Request",
    "summary": "Validate Explorer Summary Request",
}


def load(path):
    return json.load(open(path, encoding="utf-8"))


def dump(obj, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def nodes_by_name(wf):
    return {n["name"]: n for n in wf.get("nodes", [])}


def node_by_name(wf, name):
    matches = [n for n in wf.get("nodes", []) if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"{wf.get('id')}: expected exactly one node {name!r}, found {len(matches)}")
    return matches[0]


def deterministic_id(workflow_id, name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"moneytrack-api3b:{workflow_id}:{name}"))


def read_fragment(path):
    text = Path(path).read_text(encoding="utf-8").strip()
    required = [
        "MONEYTRACK_TELEGRAM_AUTH_CONTRACT_VERSION=api3b-v1",
        "function moneytrackVerifyTelegramInitData",
        "AUTH_DATE_EXPIRED",
        "timingSafeEqual",
    ]
    for marker in required:
        if marker not in text:
            raise SystemExit(f"canonical fragment missing marker: {marker}")
    return text


def env_call():
    return """const auth = moneytrackVerifyTelegramInitData({
  crypto,
  initData,
  botToken: $env.MONEYTRACK_BOT_TOKEN,
  maxAgeSeconds: $env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,
  maxFutureSkewSeconds: $env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS
});"""


def standalone_code(fragment):
    return f'''const crypto = require("crypto");

{fragment}

const initData = $json.initData || null;
{env_call()}

if (!auth.ok) {{
  return [{{
    json: {{
      auth_ok: false,
      auth_contract_version: auth.auth_contract_version,
      http_status: auth.http_status,
      error: auth.error
    }}
  }}];
}}

const passthrough = {{ ...$json }};
delete passthrough.initData;
const user = auth.user;

return [{{
  json: {{
    ...passthrough,
    auth_ok: true,
    auth_contract_version: auth.auth_contract_version,
    auth_date: auth.auth_date,
    telegram_user_id: auth.telegram_user_id,
    username: user.username || null,
    first_name: user.first_name || null,
    last_name: user.last_name || null,
    language_code: user.language_code || null
  }}
}}];'''


def auth_extractor_and_call():
    return f'''const initData =
  headers["x-telegram-init-data"] ||
  headers["X-Telegram-Init-Data"] ||
  query.initData ||
  query.init_data ||
  null;

{env_call()}

if (!auth.ok) return fail(auth.http_status, auth.error.code);
const user = auth.user;

'''


def inject_fragment_after_crypto(js, fragment):
    needle = 'const crypto = require("crypto");'
    pos = js.find(needle)
    if pos == -1:
        raise SystemExit("combined validator missing canonical crypto require")
    insert_at = pos + len(needle)
    return js[:insert_at] + "\n\n" + fragment + js[insert_at:]


def normalize_combined_validator(node, fragment):
    js = str((node.get("parameters") or {}).get("jsCode") or "")
    start = js.find("const initData =")
    if start == -1:
        raise SystemExit(f"{node.get('name')}: initData block start not found")
    success = js.rfind("return [{")
    if success == -1 or success <= start:
        raise SystemExit(f"{node.get('name')}: final success return not found")

    prefix = js[:start]
    suffix = js[success:]
    prefix = inject_fragment_after_crypto(prefix, fragment)
    node["parameters"]["jsCode"] = prefix + auth_extractor_and_call() + suffix


def if_node(wf, auth_node, name):
    x, y = (auth_node.get("position") or [0, 0])[:2]
    return {
        "parameters": {
            "conditions": {
                "options": {
                    "caseSensitive": True,
                    "leftValue": "",
                    "typeValidation": "strict",
                    "version": 3,
                },
                "conditions": [
                    {
                        "id": deterministic_id(wf["id"], name + ":condition"),
                        "leftValue": "={{ $json.auth_ok === true }}",
                        "rightValue": "",
                        "operator": {
                            "type": "boolean",
                            "operation": "true",
                            "singleValue": True,
                        },
                    }
                ],
                "combinator": "and",
            },
            "options": {},
        },
        "type": IF,
        "typeVersion": 2.3,
        "position": [x + 176, y],
        "id": deterministic_id(wf["id"], name),
        "name": name,
    }


def auth_responder(wf, name, position):
    templates = [n for n in wf.get("nodes", []) if n.get("type") == RESPOND]
    if not templates:
        raise SystemExit(f"{wf.get('id')}: no Respond to Webhook node available as typeVersion template")
    type_version = templates[0].get("typeVersion", 1.4)
    return {
        "parameters": {
            "respondWith": "json",
            "responseBody": "={{ JSON.stringify({ ok: false, error: { code: $json.error?.code || 'UNAUTHORIZED' } }) }}",
            "options": {"responseCode": "={{ $json.http_status || 401 }}"},
        },
        "type": RESPOND,
        "typeVersion": type_version,
        "position": position,
        "id": deterministic_id(wf["id"], name),
        "name": name,
    }


def main_edges(wf, source):
    return copy.deepcopy(((wf.get("connections") or {}).get(source) or {}).get("main") or [])


def normalize_standalone(label, wf, fragment):
    names = STANDALONE[label]
    responder_name = "Respond Auth Error"
    if responder_name in nodes_by_name(wf):
        raise SystemExit(f"{wf.get('id')}: {responder_name!r} already exists")

    auth_nodes = [node_by_name(wf, name) for name in names]
    max_x = max((n.get("position") or [0, 0])[0] for n in auth_nodes)
    max_y = max((n.get("position") or [0, 0])[1] for n in auth_nodes)
    responder = auth_responder(wf, responder_name, [max_x + 384, max_y + 160])
    wf["nodes"].append(responder)

    for auth in auth_nodes:
        if auth.get("type") != CODE:
            raise SystemExit(f"{wf.get('id')}: {auth.get('name')} is not Code")
        original = main_edges(wf, auth["name"])
        if len(original) != 1 or not original[0]:
            raise SystemExit(
                f"{wf.get('id')}: expected one non-empty main lane after {auth.get('name')}, got {original}"
            )

        auth["parameters"]["jsCode"] = standalone_code(fragment)
        gate_name = f"Auth Valid? {auth['name'].replace('Verify Telegram InitData ', '')}"
        gate = if_node(wf, auth, gate_name)
        wf["nodes"].append(gate)

        wf.setdefault("connections", {})[auth["name"]] = {
            "main": [[{"node": gate_name, "type": "main", "index": 0}]]
        }
        wf["connections"][gate_name] = {
            "main": [
                original[0],
                [{"node": responder_name, "type": "main", "index": 0}],
            ]
        }


def transform(label, before, fragment):
    after = copy.deepcopy(before)
    if label in STANDALONE:
        normalize_standalone(label, after, fragment)
    elif label in COMBINED:
        node = node_by_name(after, COMBINED[label])
        normalize_combined_validator(node, fragment)
    else:
        raise SystemExit(f"unknown label: {label}")
    return after


def main():
    ap = argparse.ArgumentParser()
    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        ap.add_argument(f"--{label}", required=True)
    ap.add_argument("--fragment", default="scripts/api-3-telegram-initdata-verifier.fragment.js")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()

    fragment = read_fragment(args.fragment)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    for label in ("miniapp", "delete", "reference", "transactions", "summary"):
        before = load(getattr(args, label))
        after = transform(label, before, fragment)
        dump(after, out / f"{label}.candidate.json")
        print(
            f"{label}: nodes {len(before.get('nodes', []))}->{len(after.get('nodes', []))} "
            f"auth_contract=api3b-v1"
        )

    print("API-3B auth transformer PASS")


if __name__ == "__main__":
    main()
