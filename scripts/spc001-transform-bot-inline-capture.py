#!/usr/bin/env python3
"""SPC-001: deterministic cutover of the canonical Bot inline capture graph.

The canonical Bot JSON still contains the historical inline Text writer in
parallel with the accepted Text Processor path, while Photo/receipt processing is
intentionally inline. This transform:

* replaces Get or Create User with the accepted Space-owned user_bootstrap_v1;
* removes only the two direct edges that authorize the obsolete inline Text
  branch, leaving the Text Processor path and response topology intact;
* replaces every live inline Photo financial resolver/write/readback node with a
  Space-native backend boundary while preserving AI/parser nodes and row shapes.

No workflow is imported or activated by this script.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "DER2Lc3dT2afyQhy"

BOOTSTRAP = "Get or Create User"
TEXT_OLD_ENTRY = "Message a model1"
TEXT_CANONICAL_ENTRY = "Prepare Text Processor Input"
TEXT_SOURCES = {"Send Processing Started Text", "test-mode"}

PHOTO_TARGETS = {
    "Check duplicate receipt",
    "Check semantic duplicate receipt",
    "Resolve account",
    "Insert transaction",
    "Insert receipt",
    "Create products",
    "Insert receipt items",
    "Get uncategorized products",
    "Get user categories",
    "Update product category",
    "Update receipt item categories TRUE",
}

BOOTSTRAP_QUERY = r'''with input_data as (
    select
        {{ $json.telegram_user_id }}::bigint as telegram_user_id,
        {{ $json.telegram_chat_id || 'null' }}::bigint as telegram_chat_id,
        nullif('{{ String($json.telegram_username || "").replace(/'/g,"''") }}','')::text as telegram_username,
        nullif('{{ String($json.telegram_first_name || "").replace(/'/g,"''") }}','')::text as telegram_first_name,
        nullif('{{ String($json.telegram_language_code || "").replace(/'/g,"''") }}','')::text as telegram_language_code,
        nullif('{{ String($json.message_text || "").replace(/'/g,"''") }}','')::text as message_text,
        nullif('{{ String($json.message_caption || "").replace(/'/g,"''") }}','')::text as message_caption,
        {{ $json.message_date || 'null' }}::bigint as message_date,
        nullif('{{ String($json.message_type || "").replace(/'/g,"''") }}','')::text as message_type,
        nullif('{{ String($json.telegram_file_id || "").replace(/'/g,"''") }}','')::text as telegram_file_id,
        {{ $json.test_mode === true ? 'true' : 'false' }}::boolean as test_mode,
        '{{ JSON.stringify($json.raw_message || {}).replaceAll("'", "''") }}'::jsonb as raw_message
), boot as (
    select b.*
      from input_data i
      cross join lateral moneytrack.user_bootstrap_v1(
          i.telegram_user_id,
          i.telegram_username,
          i.telegram_first_name,
          i.telegram_language_code
      ) b
)
select
    i.telegram_user_id,
    i.telegram_chat_id,
    i.telegram_username,
    i.telegram_first_name,
    i.telegram_language_code,
    i.message_text,
    i.message_caption,
    i.message_date,
    i.message_type,
    i.telegram_file_id,
    i.test_mode,
    i.raw_message,
    b.user_id,
    b.language_code,
    b.base_currency,
    b.report_currency,
    b.workspace_id,
    b.workspace_role,
    b.default_expense_account_id,
    b.default_income_account_id
from input_data i
cross join boot b;'''

CHECK_DUPLICATE = r'''select p.duplicate_found
from moneytrack.capture_receipt_duplicate_probe_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    nullif('{{ String($('Get user context').first().json.telegram_file_id || '').replace(/'/g,"''") }}','')::text,
    null
) p;'''

CHECK_SEMANTIC = r'''select p.semantic_duplicate_found
from moneytrack.capture_receipt_duplicate_probe_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    null,
    nullif('{{ String($json.receipt_fingerprint || '').replace(/'/g,"''") }}','')::text
) p;'''

RESOLVE_ACCOUNT = r'''select
    r.account_id,
    r.account_code,
    r.account_name,
    r.currency_code,
    r.status
from moneytrack.capture_resolve_account_space_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    null,
    'expense'::text,
    nullif('{{ String($('Parse receipt JSON').first().json.currency || '').replace(/'/g,"''") }}','')::text,
    {{ $('Get user context').first().json.default_expense_account_id || 'null' }}::bigint
) r;'''

INSERT_TRANSACTION = r'''select
    r.status,
    r.transaction_id as id,
    r.receipt_id,
    r.created_item_count,
    r.duplicate_receipt_id,
    r.capture_event_id
from moneytrack.capture_receipt_ingest_projection_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    '{{ String($('Get user context').first().json.capture_source_ref || '').replace(/'/g,"''") }}'::text,
    {{ $json.account_id }}::bigint,
    {{ $('Parse receipt JSON').first().json.total_amount }}::numeric,
    '{{ String($('Parse receipt JSON').first().json.currency || '').replace(/'/g,"''") }}'::text,
    '{{ String($('Parse receipt JSON').first().json.shop_name || '').replace(/'/g,"''") }}'::text,
    case
      when nullif('{{ String($('Parse receipt JSON').first().json.receipt_date || '').replace(/'/g,"''") }}','') is not null
      then '{{ String($('Parse receipt JSON').first().json.receipt_date || '').replace(/'/g,"''") }}'::date::timestamptz
      else coalesce(
        to_timestamp({{ $('Get user context').first().json.message_date || 'null' }}::double precision),
        current_timestamp
      )
    end,
    nullif('{{ String($('Get user context').first().json.telegram_file_id || '').replace(/'/g,"''") }}','')::text,
    nullif('{{ String($('Build receipt fingerprint').first().json.receipt_fingerprint || '').replace(/'/g,"''") }}','')::text,
    '{{ JSON.stringify($('Parse receipt JSON').first().json).replaceAll("'", "''") }}'::jsonb,
    '{{ JSON.stringify((Array.isArray($('Parse receipt JSON').first().json.items) ? $('Parse receipt JSON').first().json.items : []).map((item) => {
      const quantity=Number(item.quantity || 1);
      const unitPrice=Number(item.unit_price ?? item.price ?? item.amount ?? 0);
      return {
        item_name_original:String(item.item_name_original || item.name || '').trim(),
        item_language:item.item_language || null,
        quantity,
        unit_price:unitPrice,
        amount:Number(item.amount ?? quantity * unitPrice),
        category_id:item.category_id == null ? null : Number(item.category_id)
      };
    }).filter((item) => item.item_name_original)).replaceAll("'", "''") }}'::jsonb
) r;'''

INSERT_RECEIPT = r'''select
    {{ $('Insert transaction').first().json.receipt_id || 'null' }}::bigint as id;'''

CREATE_PRODUCTS = r'''select
    r.product_id,
    r.category_id
from moneytrack.receipt_projection_product_item_read_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    {{ $json.receipt_id }}::bigint,
    '{{ String($json.item_name_original || '').replace(/'/g,"''") }}'::text,
    {{ $json.quantity }}::numeric,
    {{ $json.unit_price }}::numeric,
    {{ $json.amount }}::numeric
) r;'''

INSERT_RECEIPT_ITEMS = r'''select
    r.receipt_item_id as id,
    {{ $json.receipt_id }}::bigint as receipt_id,
    r.product_id,
    r.category_id
from moneytrack.receipt_projection_product_item_read_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    {{ $json.receipt_id }}::bigint,
    '{{ String($json.item_name_original || '').replace(/'/g,"''") }}'::text,
    {{ $json.quantity }}::numeric,
    {{ $json.unit_price }}::numeric,
    {{ $json.amount }}::numeric
) r;'''

UNCATEGORIZED = r'''select *
from moneytrack.receipt_projection_uncategorized_products_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    {{ $('Insert receipt').first().json.id }}::bigint
);'''

CATEGORIES = r'''select id,code,name
from moneytrack.capture_categories_space_read_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint
);'''

UPDATE_PRODUCT_CATEGORY = r'''select
    updated_product_count as updated_count,
    updated_item_count,
    status
from moneytrack.receipt_projection_assign_categories_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    {{ $('Insert receipt').first().json.id }}::bigint,
    '{{ JSON.stringify($json.assignments || []).replaceAll("'", "''") }}'::jsonb
);'''

UPDATE_RECEIPT_ITEM_CATEGORIES = r'''select
    id,
    receipt_id,
    item_name_original,
    category_id,
    product_id
from moneytrack.receipt_projection_classified_item_read_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $('Get user context').first().json.space_id }}::bigint,
    {{ $('Insert receipt').first().json.id }}::bigint
);'''

REPLACEMENTS = {
    BOOTSTRAP: BOOTSTRAP_QUERY,
    "Check duplicate receipt": CHECK_DUPLICATE,
    "Check semantic duplicate receipt": CHECK_SEMANTIC,
    "Resolve account": RESOLVE_ACCOUNT,
    "Insert transaction": INSERT_TRANSACTION,
    "Insert receipt": INSERT_RECEIPT,
    "Create products": CREATE_PRODUCTS,
    "Insert receipt items": INSERT_RECEIPT_ITEMS,
    "Get uncategorized products": UNCATEGORIZED,
    "Get user categories": CATEGORIES,
    "Update product category": UPDATE_PRODUCT_CATEGORY,
    "Update receipt item categories TRUE": UPDATE_RECEIPT_ITEM_CATEGORIES,
}


def unwrap(doc):
    if isinstance(doc,list):
        if len(doc)!=1: raise SystemExit(f"expected one workflow, got {len(doc)}")
        return doc[0],True
    if isinstance(doc,dict): return doc,False
    raise SystemExit("input must be workflow object or one-element array")


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args=ap.parse_args()
    src=json.loads(Path(args.input).read_text(encoding="utf-8"))
    wf,was_array=unwrap(src)
    if wf.get("id")!=WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {wf.get('id')!r}")

    names={n.get("name") for n in wf.get("nodes",[])}
    required={BOOTSTRAP,TEXT_OLD_ENTRY,TEXT_CANONICAL_ENTRY,*TEXT_SOURCES,*PHOTO_TARGETS}
    missing=required-names
    if missing: raise SystemExit(f"canonical Bot topology drift: missing={sorted(missing)}")

    out=copy.deepcopy(wf)
    by_name={n.get("name"):n for n in out.get("nodes",[])}
    changed=[]
    for name,query in REPLACEMENTS.items():
        node=by_name[name]
        params=node.setdefault("parameters",{})
        if node.get("type")!="n8n-nodes-base.postgres" or params.get("operation")!="executeQuery":
            raise SystemExit(f"target {name!r} is not PostgreSQL executeQuery")
        params["query"]=query
        changed.append(name)

    removed_edges=0
    for source in TEXT_SOURCES:
        outputs=(out.get("connections",{}).get(source) or {}).get("main") or []
        saw_new=False
        saw_old=False
        for lane in outputs:
            if any(edge.get("node")==TEXT_CANONICAL_ENTRY for edge in lane): saw_new=True
            before=len(lane)
            lane[:]=[edge for edge in lane if edge.get("node")!=TEXT_OLD_ENTRY]
            if len(lane)!=before:
                saw_old=True
                removed_edges += before-len(lane)
        if not saw_old or not saw_new:
            raise SystemExit(f"Text authority topology mismatch at {source!r}: old={saw_old} canonical={saw_new}")
    if removed_edges!=2:
        raise SystemExit(f"expected exactly 2 obsolete Text authority edges, removed={removed_edges}")

    # The historical inline Text graph may remain physically for rollback/evidence,
    # but no canonical production source may still point directly into it.
    for source,outputs in (out.get("connections") or {}).items():
        for lane in (outputs or {}).get("main",[]) or []:
            if source in TEXT_SOURCES and any(edge.get("node")==TEXT_OLD_ENTRY for edge in lane):
                raise SystemExit(f"obsolete Text authority remains reachable from {source!r}")

    forbidden=(
        "moneytrack.receipts",
        "moneytrack.receipt_items",
        "moneytrack.user_default_accounts",
        "on conflict (user_id, product_key)",
    )
    for name in PHOTO_TARGETS|{BOOTSTRAP}:
        query=str(by_name[name].get("parameters",{}).get("query","")).lower()
        for token in forbidden:
            if token in query:
                raise SystemExit(f"legacy token {token!r} remains in transformed node {name!r}")

    Path(args.output).write_text(json.dumps([out] if was_array else out,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print("SPC-001 Bot inline capture candidate created")
    print(f"workflow_id={WORKFLOW_ID}")
    print("text_authority=PROCESSOR_ONLY")
    print(f"removed_inline_text_edges={removed_edges}")
    print("photo_authority=SPACE_NATIVE_INLINE")
    print("bootstrap=user_bootstrap_v1_space_compat")
    print("changed_nodes="+", ".join(sorted(changed)))
    print("runtime_mutation=NONE")


if __name__=="__main__":
    main()
