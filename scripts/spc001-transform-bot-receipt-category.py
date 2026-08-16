#!/usr/bin/env python3
"""SPC-001: replace the Bot manual receipt-item category mutation.

Run after the accepted BE-DOM-002 Bot cutover and SPC Bot capture transform.
Exactly one PostgreSQL node is changed; command parsing and responses are kept.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "DER2Lc3dT2afyQhy"
TARGET = "Set Item Category"

QUERY = r'''select
    r.receipt_item_id,
    r.category_hint,
    r.item_name_original,
    r.product_id,
    r.category_id,
    r.category_code,
    r.category_name,
    r.status
from moneytrack.receipt_projection_set_item_category_hint_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    {{ $json.receipt_item_id }}::bigint,
    '{{ String($json.category_hint || '').replace(/'/g,"''") }}'::text
) r;'''


def unwrap(doc):
    if isinstance(doc, list):
        if len(doc) != 1:
            raise SystemExit(f"expected one workflow, got {len(doc)}")
        return doc[0], True
    if isinstance(doc, dict):
        return doc, False
    raise SystemExit("input must be workflow object or one-element array")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    src = json.loads(Path(args.input).read_text(encoding="utf-8"))
    workflow, was_array = unwrap(src)
    if workflow.get("id") != WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {workflow.get('id')!r}")

    out = copy.deepcopy(workflow)
    changed = 0
    for node in out.get("nodes", []):
        if node.get("name") != TARGET:
            continue
        params = node.setdefault("parameters", {})
        if node.get("type") != "n8n-nodes-base.postgres" or params.get("operation") != "executeQuery":
            raise SystemExit(f"{TARGET!r} is not PostgreSQL executeQuery")
        params["query"] = QUERY
        changed += 1

    if changed != 1:
        raise SystemExit(f"expected exactly one {TARGET!r} node, changed={changed}")

    text = json.dumps(out, ensure_ascii=False)
    if "moneytrack.receipt_set_item_category_v1(" in text:
        raise SystemExit("legacy receipt_set_item_category_v1 still present")

    Path(args.output).write_text(
        json.dumps([out] if was_array else out, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("SPC-001 Bot receipt category candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print("changed_node=Set Item Category")
    print("classification=projection_specific")
    print("runtime_mutation=NONE")


if __name__ == "__main__":
    main()
