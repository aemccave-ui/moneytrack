#!/usr/bin/env python3
"""Build a BE-DOM-004 MoneyTrack workflow candidate.

Only the SQL query of the two budget writer nodes is replaced. Workflow graph,
node metadata and read-only budget consumers remain byte-for-byte equivalent.
"""

from __future__ import annotations

import copy
import hashlib
import json
import sys
from pathlib import Path


TARGETS = {"Insert Budget Rule", "Apply Budget Action"}

CREATE_QUERY = r"""select *
from moneytrack.budget_create_rule_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    nullif('{{ String($json.status || "").replace(/'/g,"''") }}','')::text,
    {{ $json.category_id || "null" }}::bigint,
    {{ $json.category_name ? "'" + String($json.category_name).replace(/'/g,"''") + "'" : "null" }}::text,
    {{ $json.amount || "null" }}::numeric,
    {{ $json.currency_code ? "'" + String($json.currency_code).replace(/'/g,"''") + "'" : "null" }}::text,
    {{ $json.recurrence_type ? "'" + String($json.recurrence_type).replace(/'/g,"''") + "'" : "null" }}::text,
    {{ $json.recurrence_interval || "null" }}::integer,
    {{ $json.valid_from ? "'" + new Date($json.valid_from).toISOString().slice(0,10) + "'" : "null" }}::date,
    {{ $json.valid_to ? "'" + new Date($json.valid_to).toISOString().slice(0,10) + "'" : "null" }}::date
);"""

ACTION_QUERY = r"""select *
from moneytrack.budget_apply_action_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $json.action ? "'" + String($json.action).replace(/'/g,"''") + "'" : "null" }}::text,
    {{ $json.budget_rule_id || "null" }}::bigint
);"""


def load_workflow(path: Path) -> tuple[list[dict], dict]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list) or len(payload) != 1:
        raise SystemExit(f"expected one exported workflow in {path}")
    return payload, payload[0]


def graph_hash(workflow: dict) -> str:
    raw = json.dumps(
        workflow.get("connections", {}),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(raw).hexdigest()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: be-dom-004-transform-budget-cutover.py "
            "<main-before.json> <main-candidate.json>"
        )

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])

    payload, before = load_workflow(src)
    candidate_payload = copy.deepcopy(payload)
    candidate = candidate_payload[0]

    before_nodes = {node["name"]: node for node in before["nodes"]}
    candidate_nodes = {node["name"]: node for node in candidate["nodes"]}

    missing = sorted(TARGETS - set(before_nodes))
    if missing:
        raise SystemExit(f"missing target nodes: {missing}")

    create_old = before_nodes["Insert Budget Rule"].get("parameters", {}).get("query", "")
    action_old = before_nodes["Apply Budget Action"].get("parameters", {}).get("query", "")

    if "insert into moneytrack.budget_rules" not in create_old.lower():
        raise SystemExit("Insert Budget Rule no longer contains expected direct INSERT")

    action_lower = action_old.lower()
    if "update moneytrack.budget_rules" not in action_lower:
        raise SystemExit("Apply Budget Action no longer contains expected direct UPDATE")
    if "delete from moneytrack.budget_rules" not in action_lower:
        raise SystemExit("Apply Budget Action no longer contains expected direct DELETE")

    candidate_nodes["Insert Budget Rule"]["parameters"]["query"] = CREATE_QUERY
    candidate_nodes["Apply Budget Action"]["parameters"]["query"] = ACTION_QUERY

    if len(candidate["nodes"]) != len(before["nodes"]):
        raise SystemExit("node count changed")
    if candidate.get("connections", {}) != before.get("connections", {}):
        raise SystemExit("workflow connections changed")

    dst.write_text(
        json.dumps(candidate_payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print("main_candidate_created=", dst)
    print("main_nodes=", len(candidate["nodes"]))
    print("main_graph_sha256=", graph_hash(candidate))
    print("status=PASS")


if __name__ == "__main__":
    main()
