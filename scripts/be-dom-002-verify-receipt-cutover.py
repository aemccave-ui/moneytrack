#!/usr/bin/env python3
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

if len(sys.argv) != 5:
    raise SystemExit(
        "usage: be-dom-002-verify-receipt-cutover.py "
        "<main-before.json> <photo-before.json> <main-candidate.json> <photo-candidate.json>"
    )

main_before_path, photo_before_path, main_after_path, photo_after_path = map(Path, sys.argv[1:])

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

main_before = load_one(main_before_path)
photo_before = load_one(photo_before_path)
main_after = load_one(main_after_path)
photo_after = load_one(photo_after_path)

expected_main = {"Get or Create User", "Set Item Category"}
expected_photo = {
    "Insert transaction",
    "Insert receipt",
    "Create products",
    "Insert receipt items",
    "Update product category",
    "Update receipt item categories TRUE",
}

for label, before, after, expected in [
    ("main", main_before, main_after, expected_main),
    ("photo", photo_before, photo_after, expected_photo),
]:
    if before.get("id") != after.get("id") or before.get("name") != after.get("name"):
        raise SystemExit(f"FAIL: {label} workflow identity changed")
    if before.get("connections") != after.get("connections"):
        raise SystemExit(f"FAIL: {label} connections changed")
    if len(before["nodes"]) != len(after["nodes"]):
        raise SystemExit(f"FAIL: {label} node count changed")

    b = node_map(before)
    a = node_map(after)
    if set(b) != set(a):
        raise SystemExit(f"FAIL: {label} node-name set changed")

    changed = {name for name in b if b[name] != a[name]}
    if changed != expected:
        raise SystemExit(
            f"FAIL: {label} changed nodes {sorted(changed)} != expected {sorted(expected)}"
        )

    for name in expected:
        if without_query(b[name]) != without_query(a[name]):
            raise SystemExit(f"FAIL: {label}/{name} changed outside parameters.query")

    b_meta = copy.deepcopy(before)
    a_meta = copy.deepcopy(after)
    b_meta.pop("nodes", None)
    a_meta.pop("nodes", None)
    if b_meta != a_meta:
        raise SystemExit(f"FAIL: {label} workflow metadata changed")

    print(f"{label}_changed_nodes=", sorted(changed))
    print(f"{label}_node_count=", len(after["nodes"]))
    print(f"{label}_graph_sha256=", graph_hash(after))
    print(f"{label}_structural_isolation=PASS")

main_nodes = node_map(main_after)
photo_nodes = node_map(photo_after)

required_calls = {
    ("main", "Get or Create User"): "moneytrack.catalog_ensure_user_categories_v1(",
    ("main", "Set Item Category"): "moneytrack.receipt_set_item_category_v1(",
    ("photo", "Insert transaction"): "moneytrack.receipt_ingest_v1(",
    ("photo", "Update product category"): "moneytrack.receipt_assign_categories_v1(",
}
for (scope, name), needle in required_calls.items():
    wf_nodes = main_nodes if scope == "main" else photo_nodes
    query = wf_nodes[name].get("parameters", {}).get("query", "")
    if needle not in query:
        raise SystemExit(f"FAIL: {scope}/{name} missing backend call {needle}")
    print(f"{scope}_{name}_backend_call=PASS")

contract_needles = {
    ("main", "Set Item Category"): ["receipt_set_item_category_v1"],
    ("photo", "Insert transaction"): ["transaction_id as id", "receipt_id"],
    ("photo", "Insert receipt"): ["as id"],
    ("photo", "Create products"): [
        "receipt_id", "item_name_original", "item_language", "quantity",
        "unit_price", "amount", "product_id", "category_id",
    ],
    ("photo", "Insert receipt items"): [
        "ri.id", "ri.receipt_id", "ri.product_id", "ri.category_id",
    ],
    ("photo", "Update product category"): [
        "updated_product_count as updated_count",
    ],
    ("photo", "Update receipt item categories TRUE"): [
        "ri.id", "ri.receipt_id", "ri.item_name_original", "ri.category_id", "ri.product_id",
    ],
}
for (scope, name), needles in contract_needles.items():
    wf_nodes = main_nodes if scope == "main" else photo_nodes
    query = wf_nodes[name].get("parameters", {}).get("query", "")
    missing = [n for n in needles if n not in query]
    if missing:
        raise SystemExit(f"FAIL: {scope}/{name} missing contract fragments {missing}")
print("adapter_output_contracts=PASS")

direct_writer = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\."
    r"(?:receipts|receipt_items|product_catalog|category_catalog)\b",
    re.I | re.S,
)

bypass = []
for scope, wf in [("main", main_after), ("photo", photo_after)]:
    for node in wf["nodes"]:
        query = node.get("parameters", {}).get("query", "")
        if query and direct_writer.search(query):
            bypass.append((scope, node.get("name")))

if bypass:
    raise SystemExit(f"FAIL: direct BE-DOM-002 writer bypass remains: {bypass}")
print("direct_receipt_catalog_writer_bypass=0")

insert_tx_query = photo_nodes["Insert transaction"]["parameters"]["query"]
if "finance_create_transaction_v1(" in insert_tx_query:
    raise SystemExit("FAIL: Photo Insert transaction still calls finance-only writer")
if "$('Parse receipt JSON').first().json" not in insert_tx_query:
    raise SystemExit("FAIL: Photo ingest no longer references canonical parsed receipt")
if "JSON.stringify" not in insert_tx_query:
    raise SystemExit("FAIL: Photo ingest does not pass normalized items JSON")
print("photo_atomic_ingest_contract=PASS")

for name in [
    "Insert receipt",
    "Create products",
    "Insert receipt items",
    "Update receipt item categories TRUE",
]:
    query = photo_nodes[name]["parameters"]["query"]
    if re.search(r"\b(insert|update|delete)\b", query, re.I):
        raise SystemExit(f"FAIL: photo/{name} is not read-only")
print("photo_compatibility_adapters_read_only=PASS")

bootstrap_query = main_nodes["Get or Create User"]["parameters"]["query"]
if re.search(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\."
    r"(?:category_catalog|category_catalog_translations)\b",
    bootstrap_query,
    re.I | re.S,
):
    raise SystemExit("FAIL: Main/Get or Create User still directly mutates categories")
if "cross join category_bootstrap" not in bootstrap_query.lower():
    raise SystemExit("FAIL: category backend CTE is not forced into execution")
print("main_category_bootstrap_cutover=PASS")
print("status=PASS")
