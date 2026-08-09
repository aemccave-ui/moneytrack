#!/usr/bin/env python3
"""API-2A workflow transformer.

Transforms fresh runtime exports of exactly three active workflows. For each
workflow, only the target PostgreSQL node's parameters.query is allowed to
change. Auth, validation, formatting, webhook paths and graph topology remain
untouched.
"""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

SPECS = {
    "transactions": {
        "id": "UX022TxApi202608",
        "node": "Get Account Transactions",
        "function": "api_transactions_read_model_v1",
        "query": """select *\nfrom moneytrack.api_transactions_read_model_v1(\n    {{ $json.telegram_user_id }}::bigint,\n    '{{ String($json.account_id).replace(/'/g, \"''\") }}'::text,\n    '{{ $json.date_from }}'::date,\n    '{{ $json.date_to }}'::date,\n    {{ $json.include_descendants ? 'true' : 'false' }}::boolean\n);""",
    },
    "summary": {
        "id": "UX022Summary202608",
        "node": "Get Explorer Summary",
        "function": "api_accounts_explorer_summary_read_model_v1",
        "query": """select *\nfrom moneytrack.api_accounts_explorer_summary_read_model_v1(\n    {{ $json.telegram_user_id }}::bigint,\n    ARRAY[{{ $json.excluded_sql }}]::bigint[],\n    '{{ $json.date_from }}'::date,\n    '{{ $json.date_to }}'::date,\n    current_date\n);""",
    },
    "reference": {
        "id": "MTxRef4Qp8Lm2Xs6",
        "node": "Get Transaction Reference",
        "function": "api_transaction_reference_read_model_v1",
        "query": """select *\nfrom moneytrack.api_transaction_reference_read_model_v1(\n    {{ $json.telegram_user_id }}::bigint\n);""",
    },
}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def find_node(workflow: dict, name: str) -> dict:
    matches = [node for node in workflow.get("nodes", []) if node.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one node {name!r}, got {len(matches)}")
    return matches[0]


def transform(kind: str, source: Path, destination: Path) -> None:
    spec = SPECS[kind]
    before = load(source)
    if before.get("id") != spec["id"]:
        raise SystemExit(
            f"{kind}: workflow id mismatch: expected {spec['id']}, got {before.get('id')}"
        )

    after = copy.deepcopy(before)
    node = find_node(after, spec["node"])
    if node.get("type") != "n8n-nodes-base.postgres":
        raise SystemExit(f"{kind}: target node is not Postgres")

    params = node.setdefault("parameters", {})
    old_query = params.get("query", "")
    if not old_query.strip():
        raise SystemExit(f"{kind}: target query is empty")
    if f"moneytrack.{spec['function']}(" in old_query:
        raise SystemExit(f"{kind}: workflow already calls target read model")

    params["query"] = spec["query"]

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(after, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"{kind}: {spec['id']} / {spec['node']} -> moneytrack.{spec['function']} = TRANSFORMED"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transactions", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    sources = {
        "transactions": args.transactions,
        "summary": args.summary,
        "reference": args.reference,
    }

    for kind, source in sources.items():
        transform(kind, source, args.out_dir / f"{kind}.candidate.json")

    print("API-2A transform complete")


if __name__ == "__main__":
    main()
