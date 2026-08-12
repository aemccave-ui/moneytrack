#!/usr/bin/env python3
"""BE-DOM-001: transform MoneyTrack Transaction Processor Text runtime export.

Input may be either a single workflow object or the one-element array produced by
`n8n export:workflow`. Only three named Postgres node queries are changed.
"""

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "f5ioJKyPTupUMV9h"
TARGETS = {
    "Insert transaction text",
    "Insert adjustment transaction",
    "Insert opening balance",
}

# Text and voice ingress are interactive creates. Their caller supplies
# message_date as Unix epoch seconds. If NLP supplies only a calendar date,
# preserve that date but combine it with the ingress clock rather than silently
# truncating to 00:00. If NLP supplies no date, preserve the complete ingress
# instant. current_timestamp is only a defensive fallback for legacy callers
# that do not yet carry message_date.
SIMPLE_QUERY = r'''select
    c.id,
    c.account_id
from moneytrack.finance_create_transaction_v1(
    {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
    {{ $json.account_id }}::bigint,
    '{{ String($("Parse transaction JSON").item.json.operation_type || "").replace(/'/g,"''") }}'::text,
    {{ $("Parse transaction JSON").item.json.amount }}::numeric,
    '{{ String($("Parse transaction JSON").item.json.currency || "").replace(/'/g,"''") }}'::text,
    '{{ String($("Parse transaction JSON").item.json.description || "").replace(/'/g,"''") }}'::text,
    case
        when nullif(nullif('{{ $("Parse transaction JSON").item.json.transaction_date }}','null'),'undefined') is not null
        then (
            nullif(nullif('{{ $("Parse transaction JSON").item.json.transaction_date }}','null'),'undefined')::date::text
            || ' '
            || to_char(
                coalesce(
                    to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),
                    current_timestamp
                ),
                'HH24:MI:SS'
            )
        )::timestamp::timestamptz
        else coalesce(
            to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),
            current_timestamp
        )
    end,
    null,
    null,
    null
) c;'''

ADJUSTMENT_QUERY = r'''select
    c.id
from moneytrack.finance_create_transaction_v1(
    {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
    {{ $json.account_id }}::bigint,
    'adjustment'::text,
    {{ $json.amount }}::numeric,
    '{{ String($json.currency || "").replace(/'/g,"''") }}'::text,
    '{{ String($json.description || "").replace(/'/g,"''") }}'::text,
    case
        when nullif(nullif('{{ $json.transaction_date }}','null'),'undefined') is not null
        then (
            nullif(nullif('{{ $json.transaction_date }}','null'),'undefined')::date::text
            || ' '
            || to_char(
                coalesce(
                    to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),
                    current_timestamp
                ),
                'HH24:MI:SS'
            )
        )::timestamp::timestamptz
        else coalesce(
            to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),
            current_timestamp
        )
    end,
    null,
    null,
    null
) c;'''

OPENING_QUERY = r'''with r as (
    select
        {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint as user_id,
        {{ $('Resolve opening balance account').first().json.account_id || "null" }}::bigint as account_id,
        {{ $('Resolve opening balance account').first().json.amount || 0 }}::numeric as amount,
        '{{ String($('Resolve opening balance account').first().json.currency || "").replace(/'/g,"''") }}'::text as currency,
        '{{ new Date($('Resolve opening balance account').first().json.transaction_date).toISOString().slice(0,10) }}'::date as transaction_date,
        '{{ String($('Resolve opening balance account').first().json.status || "").replace(/'/g,"''") }}'::text as status
),
created as (
    select c.*
    from (select * from r where status = 'resolved') rr
    cross join lateral moneytrack.finance_create_transaction_v1(
        rr.user_id,
        rr.account_id,
        'openingbalance',
        rr.amount,
        rr.currency,
        'opening balance',
        rr.transaction_date::timestamptz,
        null,
        null,
        null
    ) c
)
select
    r.account_id,
    r.amount,
    r.currency,
    r.transaction_date,
    r.status as resolve_status,
    c.id,
    case
        when r.status <> 'resolved' then r.status
        when c.idempotent_replay then 'already_exists'
        else 'added'
    end as status
from r
left join created c on true;'''

REPLACEMENTS = {
    "Insert transaction text": SIMPLE_QUERY,
    "Insert adjustment transaction": ADJUSTMENT_QUERY,
    "Insert opening balance": OPENING_QUERY,
}


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

    found = {n.get("name") for n in workflow.get("nodes", []) if n.get("name") in TARGETS}
    if found != TARGETS:
        raise SystemExit(f"target node mismatch: found={sorted(found)}, expected={sorted(TARGETS)}")

    out_workflow = copy.deepcopy(workflow)
    changed = []
    for node in out_workflow["nodes"]:
        name = node.get("name")
        if name in REPLACEMENTS:
            params = node.setdefault("parameters", {})
            if params.get("operation") != "executeQuery":
                raise SystemExit(f"target node {name!r} is not executeQuery")
            params["query"] = REPLACEMENTS[name]
            changed.append(name)

    if set(changed) != TARGETS:
        raise SystemExit(f"changed node mismatch: {sorted(changed)}")

    output = [out_workflow] if was_array else out_workflow
    Path(args.output).write_text(
        json.dumps(output, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print("BE-DOM-001 Text Processor candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print("changed_nodes=" + ", ".join(sorted(changed)))
    print("interactive_timestamp=parsed_date_plus_ingress_clock_or_ingress_timestamp")
    print("ingress_clock_source=message_date_epoch_with_current_timestamp_legacy_fallback")
    print("source_idempotency=DEFERRED (no stable Telegram message/update id proven in runtime contract)")


if __name__ == "__main__":
    main()
