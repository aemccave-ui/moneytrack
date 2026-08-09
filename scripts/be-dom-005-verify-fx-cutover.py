#!/usr/bin/env python3
"""Verify BE-DOM-005 candidate isolation and zero direct FX mutation."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

TARGET = "Upsert exchange rates"
EXPECTED_WORKFLOW_ID = "eOidxxekEVyAjeep"
EXPECTED_NODE_COUNT = 5
EXPECTED_GRAPH_SHA256 = "c9a532d9d49bacc8e4f663f1a208df0408ef162765ab75f8c427b22a0792f262"
DIRECT_FX_MUTATION = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\.exchange_rates_usd\b",
    re.I | re.S,
)


def load_workflow(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or len(payload) != 1:
        raise SystemExit("expected single-workflow n8n export array")
    return payload[0]


def graph_sha256(workflow: dict) -> str:
    payload = json.dumps(
        workflow.get("connections", {}),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def node_map(workflow: dict) -> dict[str, dict]:
    return {node["name"]: node for node in workflow.get("nodes", [])}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("candidate")
    args = parser.parse_args()

    before = load_workflow(Path(args.before))
    candidate = load_workflow(Path(args.candidate))

    for label, wf in (("before", before), ("candidate", candidate)):
        if wf.get("id") != EXPECTED_WORKFLOW_ID:
            raise SystemExit(f"{label}: unexpected workflow id {wf.get('id')}")
        if len(wf.get("nodes", [])) != EXPECTED_NODE_COUNT:
            raise SystemExit(f"{label}: unexpected node count {len(wf.get('nodes', []))}")
        sha = graph_sha256(wf)
        if sha != EXPECTED_GRAPH_SHA256:
            raise SystemExit(f"{label}: unexpected graph SHA {sha}")

    if before.get("connections") != candidate.get("connections"):
        raise SystemExit("workflow topology changed")

    b = node_map(before)
    c = node_map(candidate)

    if set(b) != set(c):
        raise SystemExit("node set changed")

    changed = sorted(name for name in b if b[name] != c[name])
    print("fx_changed_nodes=", changed)

    if changed != [TARGET]:
        raise SystemExit(f"unexpected changed nodes: {changed}")

    bnode = b[TARGET]
    cnode = c[TARGET]

    # Only the SQL query text may change inside the target node parameters.
    bcopy = json.loads(json.dumps(bnode))
    ccopy = json.loads(json.dumps(cnode))
    bquery = bcopy.setdefault("parameters", {}).pop("query", None)
    cquery = ccopy.setdefault("parameters", {}).pop("query", None)

    if bcopy != ccopy:
        raise SystemExit("target node metadata/parameters changed outside query")

    if not isinstance(bquery, str) or not DIRECT_FX_MUTATION.search(bquery):
        raise SystemExit("before target no longer contains expected direct FX mutation")

    if not isinstance(cquery, str) or "moneytrack.fx_upsert_usd_rate_v1(" not in cquery:
        raise SystemExit("candidate target missing backend FX call")

    if DIRECT_FX_MUTATION.search(cquery):
        raise SystemExit("candidate target still contains direct FX mutation")

    direct_writers = []
    for node in candidate.get("nodes", []):
        query = node.get("parameters", {}).get("query", "")
        if DIRECT_FX_MUTATION.search(query):
            direct_writers.append(node.get("name"))

    if direct_writers:
        raise SystemExit(f"candidate direct FX writers remain: {direct_writers}")

    print("fx_node_count=", len(candidate["nodes"]))
    print("fx_graph_sha256=", graph_sha256(candidate))
    print("fx_structural_isolation=PASS")
    print("Upsert exchange rates_backend_call=PASS")
    print("direct_fx_writer_bypass=0")
    print("target_node_query_only_change=PASS")
    print("status=PASS")


if __name__ == "__main__":
    main()
