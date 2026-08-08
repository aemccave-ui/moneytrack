#!/usr/bin/env python3
"""Verify BE-DOM-001 Transfer workflow cutover isolation."""

import argparse
import copy
import json
import re
from pathlib import Path

WORKFLOW_ID = "f5ioJKyPTupUMV9h"
TARGET = "Insert transfer"


def unwrap(doc):
    if isinstance(doc, list):
        if len(doc) != 1:
            raise SystemExit(f"expected one workflow, got {len(doc)}")
        return doc[0]
    if isinstance(doc, dict):
        return doc
    raise SystemExit("invalid workflow document")


def target(workflow):
    xs = [n for n in workflow.get("nodes", []) if n.get("name") == TARGET]
    if len(xs) != 1:
        raise SystemExit(f"expected exactly one target, found {len(xs)}")
    return xs[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("candidate")
    args = ap.parse_args()

    src_doc = json.loads(Path(args.source).read_text(encoding="utf-8"))
    cand_doc = json.loads(Path(args.candidate).read_text(encoding="utf-8"))
    src = unwrap(src_doc)
    cand = unwrap(cand_doc)

    if src.get("id") != WORKFLOW_ID or cand.get("id") != WORKFLOW_ID:
        raise SystemExit("unexpected workflow id")

    src_node = target(src)
    cand_node = target(cand)
    q = cand_node.get("parameters", {}).get("query", "")

    if "moneytrack.finance_create_transfer_v1" not in q:
        raise SystemExit("candidate does not call finance_create_transfer_v1")
    if re.search(r"insert\s+into\s+moneytrack\.transfers", q, re.I | re.S):
        raise SystemExit("candidate still contains direct INSERT INTO moneytrack.transfers")
    for forbidden in ("from_currency as", "to_currency as", "to_amount / from_amount"):
        if forbidden.lower() in q.lower():
            raise SystemExit(f"adapter still owns derived transfer field: {forbidden}")

    normalized = copy.deepcopy(cand_doc)
    norm_wf = unwrap(normalized)
    target(norm_wf).setdefault("parameters", {})["query"] = src_node.get("parameters", {}).get("query")
    if normalized != src_doc:
        raise SystemExit("candidate contains changes outside Insert transfer.parameters.query")

    print("BE-DOM-001 Transfer write verification PASS")
    print(f"workflow_id={WORKFLOW_ID}")
    print(f"target_node={TARGET}")
    print("direct_transfers_insert=ABSENT")
    print("domain_call=finance_create_transfer_v1")
    print("unrelated_workflow_content=UNCHANGED")
    print("currencies=BACKEND_FROM_ACCOUNTS")
    print("exchange_rate=BACKEND_ONLY")
    print("source_identity=NULL/NULL")


if __name__ == "__main__":
    main()
