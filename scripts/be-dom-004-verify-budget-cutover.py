#!/usr/bin/env python3
"""Structural/contract verifier for BE-DOM-004 MoneyTrack candidate."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


TARGETS = {"Insert Budget Rule", "Apply Budget Action"}
READ_ONLY_BUDGET_NODES = {"Command setting Budget", "Report Budget"}

BUDGET_WRITER = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\.budget_rules\b",
    re.I | re.S,
)

CLOSED_DOMAIN_WRITER = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\."
    r"(?:transactions|transfers|receipts|receipt_items|product_catalog|"
    r"product_catalog_translations|category_catalog|category_catalog_translations|"
    r"app_users|user_settings|workspaces|workspace_members|accounts|"
    r"user_default_accounts|user_delete_requests)\b",
    re.I | re.S,
)


def load(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or len(payload) != 1:
        raise SystemExit(f"expected one workflow in {path}")
    return payload[0]


def graph_hash(workflow: dict) -> str:
    raw = json.dumps(
        workflow.get("connections", {}),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(raw).hexdigest()


def query(node: dict) -> str:
    return node.get("parameters", {}).get("query", "")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: be-dom-004-verify-budget-cutover.py "
            "<main-before.json> <main-candidate.json>"
        )

    before = load(Path(sys.argv[1]))
    candidate = load(Path(sys.argv[2]))

    before_nodes = {node["name"]: node for node in before["nodes"]}
    candidate_nodes = {node["name"]: node for node in candidate["nodes"]}

    changed = sorted(
        name
        for name in set(before_nodes) | set(candidate_nodes)
        if before_nodes.get(name) != candidate_nodes.get(name)
    )

    print("main_changed_nodes=", changed)
    print("main_node_count=", len(candidate["nodes"]))
    print("main_graph_sha256=", graph_hash(candidate))

    if set(changed) != TARGETS:
        raise SystemExit(f"unexpected changed node set: {changed}")

    if len(candidate["nodes"]) != len(before["nodes"]):
        raise SystemExit("node count changed")

    if candidate.get("connections", {}) != before.get("connections", {}):
        raise SystemExit("connections changed")

    if graph_hash(candidate) != graph_hash(before):
        raise SystemExit("graph fingerprint changed")

    print("main_structural_isolation=PASS")

    expected_calls = {
        "Insert Budget Rule": "budget_create_rule_v1(",
        "Apply Budget Action": "budget_apply_action_v1(",
    }

    for name, needle in expected_calls.items():
        ok = needle in query(candidate_nodes[name])
        print(f"{name}_backend_call=", "PASS" if ok else "FAIL")
        if not ok:
            raise SystemExit(f"missing backend call for {name}")

    # The two query replacements use SELECT * from functions whose SQL return
    # tables intentionally match the legacy node outputs. All formatter/
    # translation nodes are unchanged.
    if "select *" not in query(candidate_nodes["Insert Budget Rule"]).lower():
        raise SystemExit("create adapter output contract is not direct function output")
    if "select *" not in query(candidate_nodes["Apply Budget Action"]).lower():
        raise SystemExit("action adapter output contract is not direct function output")

    print("adapter_output_contracts=PASS")

    budget_bypass = []
    closed_regression = []

    for node in candidate["nodes"]:
        sql = query(node)
        if BUDGET_WRITER.search(sql):
            budget_bypass.append(node["name"])
        if CLOSED_DOMAIN_WRITER.search(sql):
            closed_regression.append(node["name"])

    print("direct_budget_writer_bypass=", len(budget_bypass))
    if budget_bypass:
        raise SystemExit(f"direct budget writers remain: {budget_bypass}")

    print("closed_domain_regression_guard=", "PASS" if not closed_regression else "FAIL")
    if closed_regression:
        raise SystemExit(f"closed-domain writers reintroduced: {closed_regression}")

    # Read-only budget reporting/settings SQL must not be swept into this phase.
    for name in READ_ONLY_BUDGET_NODES:
        if name not in before_nodes or name not in candidate_nodes:
            raise SystemExit(f"missing read-only budget node: {name}")
        if before_nodes[name] != candidate_nodes[name]:
            raise SystemExit(f"read-only budget node changed: {name}")

    print("read_only_budget_consumers_unchanged=PASS")
    print("status=PASS")


if __name__ == "__main__":
    main()
