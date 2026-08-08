#!/usr/bin/env python3
"""BE-DOM-001: transform Text Processor transfer writer to canonical backend call."""

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "f5ioJKyPTupUMV9h"
TARGET = "Insert transfer"

QUERY = r'''with r as (
    select
        {{ $("MoneyTrack Transaction Processor Text").first().json.user_id }}::bigint as user_id,
        {{ $("Resolve transfer accounts").first().json.from_account_id || "null" }}::bigint as from_account_id,
        {{ $("Resolve transfer accounts").first().json.to_account_id || "null" }}::bigint as to_account_id,
        {{ $("Resolve transfer accounts").first().json.amount_from || 0 }}::numeric as from_amount,
        {{ $("Resolve transfer accounts").first().json.amount_to || 0 }}::numeric as to_amount,
        '{{ new Date($("Resolve transfer accounts").first().json.transaction_date).toISOString().slice(0,10) }}'::date as transfer_date,
        '{{ String($("Resolve transfer accounts").first().json.operation_type || "").replace(/'/g,"''") }}'::text as transfer_type,
        '{{ String($("Resolve transfer accounts").first().json.status || "").replace(/'/g,"''") }}'::text as status
),
created as (
    select c.*
    from (select * from r where status = 'resolved') rr
    cross join lateral moneytrack.finance_create_transfer_v1(
        rr.user_id,
        rr.from_account_id,
        rr.to_account_id,
        rr.from_amount,
        rr.to_amount,
        rr.transfer_date::timestamptz,
        rr.transfer_type,
        null,
        null
    ) c
)
select
    r.from_account_id,
    r.to_account_id,
    r.from_amount,
    c.from_currency,
    r.to_amount,
    c.to_currency,
    c.exchange_rate,
    r.transfer_date,
    r.transfer_type,
    c.id,
    case
        when r.status <> 'resolved' then r.status
        else 'added'
    end as status
from r
left join created c on true;'''


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

    matches = [n for n in workflow.get("nodes", []) if n.get("name") == TARGET]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {TARGET!r}, found {len(matches)}")

    out = copy.deepcopy(workflow)
    for node in out["nodes"]:
        if node.get("name") == TARGET:
            params = node.setdefault("parameters", {})
            if params.get("operation") != "executeQuery":
                raise SystemExit("target node is not executeQuery")
            params["query"] = QUERY

    payload = [out] if was_array else out
    Path(args.output).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("BE-DOM-001 Transfer candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print(f"changed_node={TARGET}")
    print("currencies=BACKEND_FROM_ACCOUNTS")
    print("exchange_rate=BACKEND")
    print("source_identity=NULL/NULL")


if __name__ == "__main__":
    main()
