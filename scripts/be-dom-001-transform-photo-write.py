#!/usr/bin/env python3
"""BE-DOM-001: transform MoneyTrack Transaction Processor Photo runtime export.

Input may be either a single workflow object or the one-element array produced by
`n8n export:workflow`. Only the Postgres query of the named `Insert transaction`
node is changed. Receipt persistence, duplicate checks, categorization, graph
shape, connections, and unrelated expressions are intentionally untouched.
"""

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "5VC0EcFB21rwTfoI"
TARGET = "Insert transaction"

PHOTO_QUERY = r'''select
    c.*
from moneytrack.finance_create_transaction_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('Resolve account').first().json.account_id }}::bigint,
    'expense'::text,
    {{ $('Parse receipt JSON').first().json.total_amount }}::numeric,
    '{{ String($('Parse receipt JSON').first().json.currency || "").replace(/'/g,"''") }}'::text,
    '{{ String($('Parse receipt JSON').first().json.shop_name || "").replace(/'/g,"''") }}'::text,
    coalesce(
        nullif(
            nullif(
                nullif('{{ $('Parse receipt JSON').first().json.receipt_date }}', ''),
                'null'
            ),
            'undefined'
        )::timestamptz,
        current_timestamp
    ),
    null,
    null,
    null
) c;'''


def unwrap(doc):
    if isinstance(doc, list):
        if len(doc) != 1:
            raise SystemExit(f"expected exactly one workflow, got {len(doc)}")
        return doc[0], True
    if isinstance(doc, dict):
        return doc, False
    raise SystemExit("input must be a workflow object or one-element workflow array")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    src = json.loads(Path(args.input).read_text(encoding="utf-8"))
    workflow, was_array = unwrap(src)

    if workflow.get("id") != WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {workflow.get('id')!r}")

    targets = [n for n in workflow.get("nodes", []) if n.get("name") == TARGET]
    if len(targets) != 1:
        raise SystemExit(f"expected exactly one {TARGET!r} node, got {len(targets)}")

    out_workflow = copy.deepcopy(workflow)
    target = next(n for n in out_workflow["nodes"] if n.get("name") == TARGET)
    params = target.setdefault("parameters", {})
    if params.get("operation") != "executeQuery":
        raise SystemExit(f"target node {TARGET!r} is not executeQuery")

    params["query"] = PHOTO_QUERY

    output = [out_workflow] if was_array else out_workflow
    Path(args.output).write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print("BE-DOM-001 Photo Processor candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print(f"changed_node={TARGET}")
    print("source_type=NULL")
    print("source_id=NULL")
    print("base_valuation=BACKEND")
    print("receipt_aggregate_atomicity=DEFERRED")


if __name__ == "__main__":
    main()
