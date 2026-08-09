#!/usr/bin/env python3
"""Build BE-DOM-005 candidate by replacing only the FX writer SQL query."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path

TARGET = "Upsert exchange rates"
EXPECTED_WORKFLOW_ID = "eOidxxekEVyAjeep"
EXPECTED_NODE_COUNT = 5
EXPECTED_GRAPH_SHA256 = "c9a532d9d49bacc8e4f663f1a208df0408ef162765ab75f8c427b22a0792f262"

NEW_QUERY = """select *
from moneytrack.fx_upsert_usd_rate_v1(
    '{{ $json.rate_date }}'::date,
    '{{ $json.currency_code }}'::varchar,
    {{ $json.usd_rate }},
    '{{ $json.source }}'::text
);"""


def graph_sha256(workflow: dict) -> str:
    payload = json.dumps(
        workflow.get("connections", {}),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def load_workflow(path: Path) -> tuple[list, dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or len(payload) != 1:
        raise SystemExit("expected single-workflow n8n export array")
    workflow = payload[0]
    return payload, workflow


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()

    source_payload, source = load_workflow(Path(args.input))

    if source.get("id") != EXPECTED_WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {source.get('id')}")

    if len(source.get("nodes", [])) != EXPECTED_NODE_COUNT:
        raise SystemExit(f"unexpected node count: {len(source.get('nodes', []))}")

    source_graph = graph_sha256(source)
    if source_graph != EXPECTED_GRAPH_SHA256:
        raise SystemExit(f"unexpected graph SHA: {source_graph}")

    candidate_payload = copy.deepcopy(source_payload)
    candidate = candidate_payload[0]

    matches = [n for n in candidate["nodes"] if n.get("name") == TARGET]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {TARGET!r} node, got {len(matches)}")

    node = matches[0]
    if node.get("type") != "n8n-nodes-base.postgres":
        raise SystemExit(f"unexpected target node type: {node.get('type')}")

    old_query = node.get("parameters", {}).get("query", "")
    if "insert into moneytrack.exchange_rates_usd" not in old_query.lower():
        raise SystemExit("target node no longer contains expected direct FX insert")

    node.setdefault("parameters", {})["query"] = NEW_QUERY

    Path(args.output).write_text(
        json.dumps(candidate_payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print("fx_candidate_created=", args.output)
    print("fx_nodes=", len(candidate["nodes"]))
    print("fx_graph_sha256=", graph_sha256(candidate))
    print("status=PASS")


if __name__ == "__main__":
    main()
