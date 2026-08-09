#!/usr/bin/env python3
"""Structural verifier for API-2A workflow candidates."""

from __future__ import annotations

import argparse
import copy
import json
import re
from pathlib import Path

SPECS = {
    "transactions": {
        "id": "UX022TxApi202608",
        "node": "Get Account Transactions",
        "function": "api_transactions_read_model_v1",
    },
    "summary": {
        "id": "UX022Summary202608",
        "node": "Get Explorer Summary",
        "function": "api_accounts_explorer_summary_read_model_v1",
    },
    "reference": {
        "id": "MTxRef4Qp8Lm2Xs6",
        "node": "Get Transaction Reference",
        "function": "api_transaction_reference_read_model_v1",
    },
}

DIRECT_TABLE_RE = re.compile(
    r"\bmoneytrack\.(?:app_users|user_settings|accounts|transactions|transfers|"
    r"exchange_rates_usd|currencies|category_catalog|category_catalog_translations)\b",
    re.I,
)
MUTATION_RE = re.compile(
    r"\b(?:insert\s+into|update|delete\s+from)\s+moneytrack\.[A-Za-z_][A-Za-z0-9_]*",
    re.I | re.S,
)


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def by_name(workflow: dict) -> dict[str, dict]:
    result = {}
    for node in workflow.get("nodes", []):
        name = node.get("name")
        if not name or name in result:
            raise SystemExit(f"missing/duplicate node name: {name!r}")
        result[name] = node
    return result


def query_of(node: dict) -> str:
    return str(node.get("parameters", {}).get("query", ""))


def without_query(node: dict) -> dict:
    clone = copy.deepcopy(node)
    params = clone.setdefault("parameters", {})
    params.pop("query", None)
    return clone


def verify_pair(kind: str, before_path: Path, after_path: Path) -> None:
    spec = SPECS[kind]
    before = load(before_path)
    after = load(after_path)

    if before.get("id") != spec["id"] or after.get("id") != spec["id"]:
        raise SystemExit(f"{kind}: workflow id mismatch")
    if before.get("connections") != after.get("connections"):
        raise SystemExit(f"{kind}: graph topology changed")
    if len(before.get("nodes", [])) != len(after.get("nodes", [])):
        raise SystemExit(f"{kind}: node count changed")

    bnodes = by_name(before)
    anodes = by_name(after)
    if bnodes.keys() != anodes.keys():
        raise SystemExit(f"{kind}: node names changed")

    changed = sorted(name for name in bnodes if bnodes[name] != anodes[name])
    if changed != [spec["node"]]:
        raise SystemExit(f"{kind}: unexpected changed nodes: {changed}")

    btarget = bnodes[spec["node"]]
    atarget = anodes[spec["node"]]
    if without_query(btarget) != without_query(atarget):
        raise SystemExit(f"{kind}: target changed outside parameters.query")

    query = query_of(atarget)
    required = f"moneytrack.{spec['function']}("
    if required not in query:
        raise SystemExit(f"{kind}: target backend read-model call missing")
    if DIRECT_TABLE_RE.search(query):
        raise SystemExit(f"{kind}: direct business-table read remains in target query")
    if MUTATION_RE.search(query):
        raise SystemExit(f"{kind}: direct mutation found in target query")

    for node in after.get("nodes", []):
        if MUTATION_RE.search(query_of(node)):
            raise SystemExit(f"{kind}: direct mutation found in node {node.get('name')}")

    print(
        f"{kind}: graph parity PASS; changed node={spec['node']}; query-only PASS; "
        f"backend={spec['function']} PASS"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    for kind in SPECS:
        parser.add_argument(f"--{kind}-before", type=Path, required=True)
        parser.add_argument(f"--{kind}-after", type=Path, required=True)
    args = parser.parse_args()

    for kind in SPECS:
        verify_pair(
            kind,
            getattr(args, f"{kind}_before"),
            getattr(args, f"{kind}_after"),
        )

    print("API-2A structural cutover verifier PASS")


if __name__ == "__main__":
    main()
