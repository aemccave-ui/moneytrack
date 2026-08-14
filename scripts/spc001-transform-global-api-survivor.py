#!/usr/bin/env python3
"""SPC-001E1: preserve the non-financial global HTTP surface in MiniApp API.

The canonical API program keeps GET /api/v1/i18n and GET /api/v1/me active.
SPC-001 replaces financial HTTP routes with Space-native adapters, so the mixed
legacy workflow must survive only as the owner of those two user-global routes.

This transform is source-only/file-only. It never imports, publishes or mutates
n8n. It removes only replaceable webhook ingress nodes and their source
connection entries; all remaining nodes and connections are byte-semantically
preserved in the JSON object.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "7TJ2xQTxLsTydXZc"
SURVIVOR_ROUTES = {
    ("GET", "api/v1/i18n"),
    ("GET", "api/v1/me"),
}


def die(message: str) -> None:
    raise SystemExit("SPC001_GLOBAL_API_SURVIVOR=FAIL " + message)


def unwrap(doc):
    if isinstance(doc, dict):
        return doc, False
    if isinstance(doc, list) and len(doc) == 1 and isinstance(doc[0], dict):
        return doc[0], True
    die("input_must_be_one_workflow")


def route(node: dict) -> tuple[str, str] | None:
    if node.get("type") != "n8n-nodes-base.webhook":
        return None
    params = node.get("parameters") or {}
    path = str(params.get("path") or "").strip().lstrip("/")
    if not path:
        die(f"webhook_path_missing node={node.get('name')!r}")
    method = str(params.get("httpMethod") or "GET").strip().upper()
    return method, path


def route_set(workflow: dict) -> set[tuple[str, str]]:
    result: set[tuple[str, str]] = set()
    for node in workflow.get("nodes", []):
        found = route(node)
        if found:
            if found in result:
                die(f"duplicate_route route={found!r}")
            result.add(found)
    return result


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    args = ap.parse_args()

    raw = json.loads(args.input.read_text(encoding="utf-8"))
    workflow, was_array = unwrap(raw)
    if str(workflow.get("id") or "") != WORKFLOW_ID:
        die(f"workflow_id expected={WORKFLOW_ID} actual={workflow.get('id')!r}")

    before_routes = route_set(workflow)
    missing = sorted(SURVIVOR_ROUTES - before_routes)
    if missing:
        die("required_survivor_routes_missing=" + json.dumps(missing))

    before_nodes = {str(n.get("name")): n for n in workflow.get("nodes", []) if n.get("name")}
    if len(before_nodes) != len(workflow.get("nodes", [])):
        die("node_name_missing_or_duplicate")

    removed_names: set[str] = set()
    removed_routes: set[tuple[str, str]] = set()
    for node in workflow.get("nodes", []):
        found = route(node)
        if found and found not in SURVIVOR_ROUTES:
            removed_names.add(str(node["name"]))
            removed_routes.add(found)

    if not removed_names:
        die("no_replaceable_webhook_ingress_found")

    # A Webhook is an ingress. Fail closed if any graph edge targets a webhook
    # that we intend to remove; then pruning only source entries would be unsafe.
    incoming = []
    for source, connection in (workflow.get("connections") or {}).items():
        for lane in (connection or {}).get("main") or []:
            for edge in lane:
                if edge.get("node") in removed_names:
                    incoming.append((source, edge.get("node")))
    if incoming:
        die("replaceable_webhook_has_incoming_edges=" + json.dumps(sorted(incoming)))

    candidate = copy.deepcopy(workflow)
    candidate["nodes"] = [
        n for n in candidate.get("nodes", [])
        if str(n.get("name") or "") not in removed_names
    ]
    candidate["connections"] = {
        source: connection
        for source, connection in (candidate.get("connections") or {}).items()
        if source not in removed_names
    }

    after_routes = route_set(candidate)
    if after_routes != SURVIVOR_ROUTES:
        die(
            "survivor_route_set "
            + json.dumps({"actual": sorted(after_routes), "expected": sorted(SURVIVOR_ROUTES)})
        )

    after_nodes = {str(n.get("name")): n for n in candidate.get("nodes", []) if n.get("name")}
    kept_names = set(before_nodes) - removed_names
    if set(after_nodes) != kept_names:
        die("kept_node_set_changed")
    for name in sorted(kept_names):
        if after_nodes[name] != before_nodes[name]:
            die(f"kept_node_changed name={name!r}")

    before_connections = workflow.get("connections") or {}
    after_connections = candidate.get("connections") or {}
    expected_sources = set(before_connections) - removed_names
    if set(after_connections) != expected_sources:
        die("connection_source_set_changed")
    for source in sorted(expected_sources):
        if after_connections[source] != before_connections[source]:
            die(f"kept_connection_changed source={source!r}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps([candidate] if was_array else candidate, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"workflow_id={WORKFLOW_ID}")
    print("GLOBAL_SURVIVOR_ROUTES=PASS routes=" + json.dumps(sorted(SURVIVOR_ROUTES)))
    print(f"REPLACEABLE_WEBHOOK_INGRESS_REMOVED=PASS count={len(removed_names)}")
    print("KEPT_NODES_AND_CONNECTIONS_UNCHANGED=PASS")
    print("DB_MUTATION=NONE")
    print("N8N_MUTATION=NONE")
    print("SPC001_GLOBAL_API_SURVIVOR=PASS")


if __name__ == "__main__":
    main()
