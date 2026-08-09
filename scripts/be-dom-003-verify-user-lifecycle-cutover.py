#!/usr/bin/env python3
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit(
        "usage: be-dom-003-verify-user-lifecycle-cutover.py "
        "<main-before.json> <main-candidate.json>"
    )

before_path, after_path = map(Path, sys.argv[1:])

def load_one(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or len(data) != 1:
        raise SystemExit(f"FAIL: expected one exported workflow in {path}")
    return data[0]

def node_map(wf):
    return {n["name"]: n for n in wf["nodes"]}

def graph_hash(wf):
    payload = json.dumps(
        wf.get("connections", {}),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()

def without_query(node):
    x = copy.deepcopy(node)
    params = x.get("parameters")
    if isinstance(params, dict):
        params.pop("query", None)
    return x

before = load_one(before_path)
after = load_one(after_path)

expected = {
    "Command Start",
    "Get or Create User",
    "Create Delete Me Request",
    "Set default account",
    "Update Language",
    "Update User Currency",
}

if before.get("id") != after.get("id") or before.get("name") != after.get("name"):
    raise SystemExit("FAIL: workflow identity changed")
if before.get("connections") != after.get("connections"):
    raise SystemExit("FAIL: workflow connections changed")
if len(before["nodes"]) != len(after["nodes"]):
    raise SystemExit("FAIL: workflow node count changed")

b = node_map(before)
a = node_map(after)
if set(b) != set(a):
    raise SystemExit("FAIL: node-name set changed")

changed = {name for name in b if b[name] != a[name]}
if changed != expected:
    raise SystemExit(
        f"FAIL: changed nodes {sorted(changed)} != expected {sorted(expected)}"
    )

for name in expected:
    if without_query(b[name]) != without_query(a[name]):
        raise SystemExit(f"FAIL: {name} changed outside parameters.query")

b_meta = copy.deepcopy(before)
a_meta = copy.deepcopy(after)
b_meta.pop("nodes", None)
a_meta.pop("nodes", None)
if b_meta != a_meta:
    raise SystemExit("FAIL: workflow metadata changed")

print("main_changed_nodes=", sorted(changed))
print("main_node_count=", len(after["nodes"]))
print("main_graph_sha256=", graph_hash(after))
print("main_structural_isolation=PASS")

required_calls = {
    "Command Start": "moneytrack.user_bootstrap_v1(",
    "Get or Create User": "moneytrack.user_bootstrap_v1(",
    "Create Delete Me Request": "moneytrack.user_create_delete_request_v1(",
    "Set default account": "moneytrack.user_set_default_account_v1(",
    "Update Language": "moneytrack.user_set_language_v1(",
    "Update User Currency": "moneytrack.user_set_currency_v1(",
}
for name, needle in required_calls.items():
    query = a[name].get("parameters", {}).get("query", "")
    if needle not in query:
        raise SystemExit(f"FAIL: {name} missing backend call {needle}")
    print(f"{name}_backend_call=PASS")

contract_needles = {
    "Command Start": [
        "b.user_id", "b.telegram_user_id", "b.language_code",
        "b.base_currency", "b.report_currency", "b.workspace_id", "b.workspace_role",
    ],
    "Get or Create User": [
        "i.test_mode", "i.telegram_user_id", "i.telegram_chat_id", "i.telegram_username",
        "i.telegram_first_name", "i.telegram_language_code", "i.message_text",
        "i.message_caption", "i.message_date", "i.message_type", "i.telegram_file_id",
        "i.raw_message", "b.language_code as fallback_language_code",
        "b.workspace_id", "b.default_expense_account_id", "b.default_income_account_id",
    ],
    "Create Delete Me Request": ["id", "confirmation_code", "expires_at"],
    "Set default account": ["currency_code", "account_hint", "account_name", "account_code", "status"],
    "Update Language": ["requested_language_code", "language_code", "is_valid", "status"],
    "Update User Currency": [
        "currency_type", "currency_code", "status", "is_valid",
        "base_currency", "report_currency", "available_currencies",
    ],
}
for name, needles in contract_needles.items():
    query = a[name].get("parameters", {}).get("query", "")
    missing = [needle for needle in needles if needle not in query]
    if missing:
        raise SystemExit(f"FAIL: {name} missing output-contract fragments {missing}")
print("adapter_output_contracts=PASS")

lifecycle_writer = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\."
    r"(?:app_users|user_settings|workspaces|workspace_members|accounts|"
    r"user_default_accounts|user_delete_requests)\b",
    re.I | re.S,
)

bypass = []
for node in after["nodes"]:
    query = node.get("parameters", {}).get("query", "")
    if query and lifecycle_writer.search(query):
        bypass.append(node.get("name"))
if bypass:
    raise SystemExit(f"FAIL: lifecycle writer bypass remains: {bypass}")
print("direct_user_lifecycle_writer_bypass=0")

# Protect already-closed domains from accidental reintroduction in changed nodes.
closed_domain_writer = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\."
    r"(?:transactions|transfers|receipts|receipt_items|product_catalog|"
    r"product_catalog_translations|category_catalog|category_catalog_translations)\b",
    re.I | re.S,
)
for name in expected:
    query = a[name].get("parameters", {}).get("query", "")
    if closed_domain_writer.search(query):
        raise SystemExit(f"FAIL: {name} reintroduced closed-domain direct mutation")
print("closed_domain_regression_guard=PASS")

bootstrap_a = a["Command Start"]["parameters"]["query"]
bootstrap_b = a["Get or Create User"]["parameters"]["query"]
if bootstrap_a.count("user_bootstrap_v1(") != 1 or bootstrap_b.count("user_bootstrap_v1(") != 1:
    raise SystemExit("FAIL: canonical bootstrap call count mismatch")
if "catalog_ensure_user_categories_v1(" in bootstrap_a or "catalog_ensure_user_categories_v1(" in bootstrap_b:
    raise SystemExit("FAIL: adapter directly invokes category bootstrap")
print("canonical_bootstrap_unification=PASS")

print("status=PASS")
