#!/usr/bin/env python3
"""SPC-001: transform the accepted BE-DOM-002 Photo Processor candidate.

The AI/parser graph is preserved. Exactly six financial persistence/readback
nodes are replaced so receipt ingestion is one Space-native atomic backend call,
parser facts live on capture source, and category/product state is projection-
specific / Space-local.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "5VC0EcFB21rwTfoI"
TARGETS = {
    "Insert transaction",
    "Insert receipt",
    "Create products",
    "Insert receipt items",
    "Update product category",
    "Update receipt item categories TRUE",
}

INSERT_TRANSACTION_QUERY = r'''select
    r.status,
    r.transaction_id as id,
    r.receipt_id,
    r.created_item_count,
    r.duplicate_receipt_id,
    r.capture_event_id
from moneytrack.capture_receipt_ingest_projection_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Photo').first().json.space_id }}::bigint,
    '{{ String($('MoneyTrack Transaction Processor Photo').first().json.capture_source_ref || '').replace(/'/g,"''") }}'::text,
    {{ $json.account_id }}::bigint,
    {{ $('Parse receipt JSON').item.json.total }}::numeric,
    '{{ String($('Parse receipt JSON').item.json.currency || '').replace(/'/g,"''") }}'::text,
    '{{ String($('Parse receipt JSON').item.json.merchant || '').replace(/'/g,"''") }}'::text,
    case
      when nullif('{{ String($('Parse receipt JSON').item.json.receipt_date || '').replace(/'/g,"''") }}','') is not null
      then '{{ String($('Parse receipt JSON').item.json.receipt_date || '').replace(/'/g,"''") }}'::date::timestamptz
      else coalesce(
        to_timestamp({{ $('MoneyTrack Transaction Processor Photo').first().json.message_date || 'null' }}::double precision),
        current_timestamp
      )
    end,
    nullif('{{ String($('MoneyTrack Transaction Processor Photo').first().json.telegram_file_id || '').replace(/'/g,"''") }}','')::text,
    nullif('{{ String($('Build receipt fingerprint').item.json.receipt_fingerprint || '').replace(/'/g,"''") }}','')::text,
    '{{ JSON.stringify($('Parse receipt JSON').item.json.raw_ai_json || $('Parse receipt JSON').item.json).replaceAll("'", "''") }}'::jsonb,
    '{{ JSON.stringify((Array.isArray($('Parse receipt JSON').item.json.items) ? $('Parse receipt JSON').item.json.items : []).map((item) => ({
      item_name_original: String(item.item_name_original || item.description || item.name || '').trim(),
      item_language: item.item_language || null,
      quantity: Number(item.quantity || 1),
      unit_price: Number(item.unit_price ?? item.price ?? item.amount ?? 0),
      amount: Number(item.amount ?? ((item.quantity || 1) * (item.unit_price ?? item.price ?? 0))),
      category_id: item.category_id == null ? null : Number(item.category_id)
    })).filter((item) => item.item_name_original)).replaceAll("'", "''") }}'::jsonb
) r;'''

INSERT_RECEIPT_QUERY = r'''select
    {{ $('Insert transaction').first().json.receipt_id || 'null' }}::bigint as id;'''

CREATE_PRODUCTS_QUERY = r'''select
    r.product_id,
    r.category_id
from moneytrack.receipt_projection_product_item_read_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Photo').first().json.space_id }}::bigint,
    {{ $json.receipt_id }}::bigint,
    '{{ String($json.item_name_original || '').replace(/'/g,"''") }}'::text,
    {{ $json.quantity }}::numeric,
    {{ $json.unit_price }}::numeric,
    {{ $json.amount }}::numeric
) r;'''

INSERT_RECEIPT_ITEMS_QUERY = r'''select
    r.receipt_item_id as id,
    {{ $json.receipt_id }}::bigint as receipt_id,
    r.product_id,
    r.category_id
from moneytrack.receipt_projection_product_item_read_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Photo').first().json.space_id }}::bigint,
    {{ $json.receipt_id }}::bigint,
    '{{ String($json.item_name_original || '').replace(/'/g,"''") }}'::text,
    {{ $json.quantity }}::numeric,
    {{ $json.unit_price }}::numeric,
    {{ $json.amount }}::numeric
) r;'''

UPDATE_PRODUCT_CATEGORY_QUERY = r'''select
    updated_product_count as updated_count,
    updated_item_count,
    status
from moneytrack.receipt_projection_assign_categories_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Photo').first().json.space_id }}::bigint,
    {{ $('Insert receipt').first().json.id }}::bigint,
    '{{ JSON.stringify($json.assignments || []).replaceAll("'", "''") }}'::jsonb
);'''

UPDATE_RECEIPT_ITEM_CATEGORIES_TRUE_QUERY = r'''select
    id,
    receipt_id,
    item_name_original,
    category_id,
    product_id
from moneytrack.receipt_projection_classified_item_read_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Photo').first().json.space_id }}::bigint,
    {{ $('Insert receipt').first().json.id }}::bigint
);'''

REPLACEMENTS = {
    "Insert transaction": INSERT_TRANSACTION_QUERY,
    "Insert receipt": INSERT_RECEIPT_QUERY,
    "Create products": CREATE_PRODUCTS_QUERY,
    "Insert receipt items": INSERT_RECEIPT_ITEMS_QUERY,
    "Update product category": UPDATE_PRODUCT_CATEGORY_QUERY,
    "Update receipt item categories TRUE": UPDATE_RECEIPT_ITEM_CATEGORIES_TRUE_QUERY,
}

FORBIDDEN_IN_TARGETS = (
    "moneytrack.receipt_ingest_v1(",
    "moneytrack.receipt_assign_categories_v1(",
    "moneytrack.receipt_items",
    "pc.user_id",
)


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

    out = copy.deepcopy(workflow)
    changed = []
    for node in out.get("nodes", []):
        name = node.get("name")
        if name not in REPLACEMENTS:
            continue
        params = node.setdefault("parameters", {})
        if params.get("operation") != "executeQuery":
            raise SystemExit(f"target node {name!r} is not executeQuery")
        params["query"] = REPLACEMENTS[name]
        changed.append(name)

    if set(changed) != TARGETS:
        raise SystemExit(f"changed node mismatch: {sorted(changed)}")

    for node in out.get("nodes", []):
        if node.get("name") not in TARGETS:
            continue
        query = str(node.get("parameters", {}).get("query", ""))
        for token in FORBIDDEN_IN_TARGETS:
            if token in query:
                raise SystemExit(f"legacy token {token!r} remains in {node.get('name')!r}")

    Path(args.output).write_text(
        json.dumps([out] if was_array else out, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("SPC-001 Photo Processor candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print("changed_nodes=" + ", ".join(sorted(changed)))
    print("receipt_ingress=atomic_capture_projection")
    print("duplicate_contract=exact_plus_semantic")
    print("classification=projection_specific")
    print("runtime_mutation=NONE")


if __name__ == "__main__":
    main()
