#!/usr/bin/env python3
"""Verify a BE-DOM-001 Photo Processor source/candidate pair.

The gate proves that the candidate delegates `Insert transaction` to the finance
write boundary and that, after normalizing only that target query, the complete
workflow document is byte-semantically identical as parsed JSON.
"""

import argparse
import copy
import json
import runpy
from pathlib import Path

HERE = Path(__file__).resolve().parent
TRANSFORM = runpy.run_path(str(HERE / "be-dom-001-transform-photo-write.py"))
WORKFLOW_ID = TRANSFORM["WORKFLOW_ID"]
TARGET = TRANSFORM["TARGET"]
PHOTO_QUERY = TRANSFORM["PHOTO_QUERY"]


def unwrap(doc):
    if isinstance(doc, list):
        if len(doc) != 1:
            raise SystemExit(f"expected exactly one workflow, got {len(doc)}")
        return doc[0]
    if isinstance(doc, dict):
        return doc
    raise SystemExit("input must be a workflow object or one-element workflow array")


def target_node(workflow):
    nodes = [n for n in workflow.get("nodes", []) if n.get("name") == TARGET]
    if len(nodes) != 1:
        raise SystemExit(f"expected exactly one {TARGET!r} node, got {len(nodes)}")
    return nodes[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("candidate")
    args = ap.parse_args()

    source_doc = json.loads(Path(args.source).read_text(encoding="utf-8"))
    candidate_doc = json.loads(Path(args.candidate).read_text(encoding="utf-8"))
    source = unwrap(source_doc)
    candidate = unwrap(candidate_doc)

    if source.get("id") != WORKFLOW_ID or candidate.get("id") != WORKFLOW_ID:
        raise SystemExit("workflow id mismatch")

    source_target = target_node(source)
    candidate_target = target_node(candidate)
    query = candidate_target.get("parameters", {}).get("query")

    if query != PHOTO_QUERY:
        raise SystemExit("candidate target query does not match canonical Photo query")

    lowered = query.lower()
    if "finance_create_transaction_v1" not in lowered:
        raise SystemExit("finance_create_transaction_v1 call missing")
    if "insert into moneytrack.transactions" in lowered:
        raise SystemExit("direct INSERT into moneytrack.transactions remains")
    for forbidden in ("amount_base", "currency_base", "exchange_rate"):
        if forbidden in lowered:
            raise SystemExit(f"adapter still owns derived finance field: {forbidden}")

    normalized = copy.deepcopy(candidate_doc)
    normalized_workflow = unwrap(normalized)
    normalized_target = target_node(normalized_workflow)
    normalized_target.setdefault("parameters", {})["query"] = source_target.get("parameters", {}).get("query")

    if normalized != source_doc:
        raise SystemExit("candidate contains changes outside Insert transaction.parameters.query")

    print("BE-DOM-001 Photo write verification PASS")
    print(f"workflow_id={WORKFLOW_ID}")
    print(f"target_node={TARGET}")
    print("direct_transactions_insert=ABSENT")
    print("domain_call=finance_create_transaction_v1")
    print("unrelated_workflow_content=UNCHANGED")
    print("source_identity=NULL/NULL")
    print("derived_base_fields=BACKEND_ONLY")


if __name__ == "__main__":
    main()
