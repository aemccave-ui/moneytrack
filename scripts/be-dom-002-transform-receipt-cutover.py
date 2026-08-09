#!/usr/bin/env python3
import copy
import hashlib
import json
import re
import sys
from pathlib import Path

if len(sys.argv) != 5:
    raise SystemExit(
        "usage: be-dom-002-transform-receipt-cutover.py "
        "<main-before.json> <photo-before.json> <main-candidate.json> <photo-candidate.json>"
    )

main_src, photo_src, main_dst, photo_dst = map(Path, sys.argv[1:])

def load(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list) or len(data) != 1:
        raise SystemExit(f"ERROR: expected one exported workflow in {path}")
    return data

def node_by_name(wf, name):
    matches = [n for n in wf["nodes"] if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one node {name!r}, found {len(matches)}")
    return matches[0]

def set_query(wf, name, query):
    node = node_by_name(wf, name)
    if node.get("type") != "n8n-nodes-base.postgres":
        raise SystemExit(f"ERROR: {name!r} is not a Postgres node")
    node.setdefault("parameters", {})["query"] = query.strip() + "\n"

main_data = load(main_src)
photo_data = load(photo_src)
main_before = main_data[0]
photo_before = photo_data[0]
main_after = copy.deepcopy(main_before)
photo_after = copy.deepcopy(photo_before)

# Main / Get or Create User: preserve the existing user/workspace/account/settings
# bootstrap, but replace inline category tree + translation writers with the
# serialized backend bootstrap boundary. The final CROSS JOIN forces execution.
bootstrap_node = node_by_name(main_after, "Get or Create User")
bootstrap_sql = bootstrap_node["parameters"]["query"]

category_block = re.compile(
    r"(?is)\btemplate_categories\s+as\s*\(.*?\n\s*settings_upsert\s+as\s*\("
)
replacement = """category_bootstrap as (
    select *
    from moneytrack.catalog_ensure_user_categories_v1(
        (select id from user_upsert)
    )
),

settings_upsert as ("""

bootstrap_sql, count = category_block.subn(replacement, bootstrap_sql, count=1)
if count != 1:
    raise SystemExit(
        f"ERROR: Get or Create User category block replacement count={count}, expected 1"
    )

final_from_old = re.compile(
    r"(?is)from\s+user_upsert\s+u\s+cross\s+join\s+resolved_input\s+r\s+"
    r"join\s+settings_upsert\s+s\s+on\s+s\.user_id\s*=\s*u\.id"
)
final_from_new = """from user_upsert u
cross join resolved_input r
cross join category_bootstrap cb
join settings_upsert s
    on s.user_id = u.id"""
bootstrap_sql, count = final_from_old.subn(final_from_new, bootstrap_sql, count=1)
if count != 1:
    raise SystemExit(
        f"ERROR: Get or Create User final bootstrap-force replacement count={count}, expected 1"
    )
bootstrap_node["parameters"]["query"] = bootstrap_sql

# Main / Set Item Category: preserve the old row contract while ownership,
# category matching and product+item mutation move into the backend function.
set_query(
    main_after,
    "Set Item Category",
    r"""
select *
from moneytrack.receipt_set_item_category_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $json.receipt_item_id || 'null' }}::bigint,
    nullif('{{ String($json.category_hint || "").replace(/'/g,"''") }}','')::text
);
""",
)

# Photo / Insert transaction becomes the one atomic receipt-ingest writer.
# Items are normalized with the same behavior as the existing Prepare receipt
# items code node so the backend sees a legacy-compatible payload.
set_query(
    photo_after,
    "Insert transaction",
    r"""
with ingested as (
    select *
    from moneytrack.receipt_ingest_v1(
        {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
        {{ $('Resolve account').first().json.account_id }}::bigint,
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
            )::date,
            to_timestamp(
                {{ $('MoneyTrack Transaction Processor Photo').first().json.message_date }}
            )::date
        ),
        nullif(
            '{{ String($('MoneyTrack Transaction Processor Photo').first().json.telegram_file_id || "").replace(/'/g,"''") }}',
            ''
        )::text,
        nullif(
            '{{ String($('Build receipt fingerprint').first().json.receipt_fingerprint || "").replace(/'/g,"''") }}',
            ''
        )::text,
        $json${{ JSON.stringify($('Parse receipt JSON').first().json) }}$json$::jsonb,
        $json${{
            JSON.stringify((() => {
                const receipt = $('Parse receipt JSON').first().json;
                const items = Array.isArray(receipt.items) ? receipt.items : [];
                const languageMap = {
                    spanish: 'es',
                    español: 'es',
                    espanol: 'es',
                    es: 'es',
                    russian: 'ru',
                    русский: 'ru',
                    ru: 'ru',
                    english: 'en',
                    inglés: 'en',
                    ingles: 'en',
                    en: 'en'
                };
                return items.map(item => {
                    const quantity = Number(item.quantity || 1);
                    const unitPrice = Number(item.unit_price || item.price || item.amount || 0);
                    const amount = Number(item.amount || quantity * unitPrice || 0);
                    const languageKey = String(
                        item.item_language || receipt.language || ''
                    ).trim().toLowerCase();
                    return {
                        item_name_original: item.item_name_original || item.name || '',
                        item_language: languageMap[languageKey] || 'es',
                        quantity,
                        unit_price: unitPrice,
                        amount,
                        category_id: item.category_id || null
                    };
                });
            })())
        }}$json$::jsonb
    )
)
select
    transaction_id as id,
    receipt_id,
    status as receipt_ingest_status,
    created_item_count,
    duplicate_receipt_id
from ingested;
""",
)

# Preserve old Insert receipt output (one id row) without a second write.
set_query(
    photo_after,
    "Insert receipt",
    r"""
select
    {{ $('Insert transaction').first().json.receipt_id || 'null' }}::bigint as id;
""",
)

# Preserve one output row per prepared input item. Product resolution is read-only
# because receipt_ingest_v1 has already upserted the catalog.
set_query(
    photo_after,
    "Create products",
    r"""
with input_data as (
    select
        {{ $json.receipt_id }}::bigint as receipt_id,
        '{{ String($json.item_name_original || "").replace(/'/g, "''") }}'::text as item_name_original,
        {{ $json.item_language ? "'" + $json.item_language + "'" : "null" }}::text as item_language,
        {{ $json.quantity }}::numeric as quantity,
        {{ $json.unit_price }}::numeric as unit_price,
        {{ $json.amount }}::numeric as amount,
        {{ $json.category_id || "null" }}::bigint as category_id
),
resolved as (
    select
        pc.id as product_id,
        pc.category_id
    from moneytrack.product_catalog pc
    where pc.user_id =
        {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint
      and pc.product_key = lower(
          regexp_replace(
              '{{ String($json.item_name_original || "").replace(/'/g, "''") }}',
              '[^a-zA-Zа-яА-Я0-9]+',
              '_',
              'g'
          )
      )
    order by pc.id
    limit 1
)
select
    i.receipt_id,
    i.item_name_original,
    i.item_language,
    i.quantity,
    i.unit_price,
    i.amount,
    r.product_id,
    coalesce(i.category_id, r.category_id) as category_id
from input_data i
left join resolved r on true;
""",
)

# Preserve Insert receipt items' output shape by reading the row already created
# atomically by receipt_ingest_v1.
set_query(
    photo_after,
    "Insert receipt items",
    r"""
select
    ri.id,
    ri.receipt_id,
    ri.product_id,
    ri.category_id
from moneytrack.receipt_items ri
where ri.receipt_id = {{ $json.receipt_id }}::bigint
  and ri.product_id is not distinct from {{ $json.product_id || "null" }}::bigint
  and coalesce(ri.item_name_original, '') =
      '{{ String($json.item_name_original || "").replace(/'/g, "''") }}'
  and ri.quantity is not distinct from {{ $json.quantity }}::numeric
  and ri.unit_price is not distinct from {{ $json.unit_price }}::numeric
  and ri.amount is not distinct from {{ $json.amount }}::numeric
order by ri.id
limit 1;
""",
)

# Backend category assignment owns product mutation and receipt-item propagation.
# Keep updated_count for the existing adapter contract.
set_query(
    photo_after,
    "Update product category",
    r"""
select
    updated_product_count as updated_count,
    updated_item_count,
    status
from moneytrack.receipt_assign_categories_v1(
    {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
    {{ $('Insert receipt').first().json.id }}::bigint,
    $json${{ JSON.stringify($json.assignments || []) }}$json$::jsonb
);
""",
)

# The previous node already propagated categories. Keep this topology node as a
# one-row read-back trigger with the legacy columns, avoiding downstream fan-out.
set_query(
    photo_after,
    "Update receipt item categories TRUE",
    r"""
select
    ri.id,
    ri.receipt_id,
    ri.item_name_original,
    ri.category_id,
    ri.product_id
from moneytrack.receipt_items ri
join moneytrack.product_catalog pc
  on pc.id = ri.product_id
where ri.receipt_id = {{ $('Insert receipt').first().json.id }}::bigint
  and pc.user_id =
      {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint
  and ri.category_id is not null
order by ri.id
limit 1;
""",
)

main_data[0] = main_after
photo_data[0] = photo_after
main_dst.write_text(json.dumps(main_data, ensure_ascii=False, indent=2), encoding="utf-8")
photo_dst.write_text(json.dumps(photo_data, ensure_ascii=False, indent=2), encoding="utf-8")

def graph_hash(wf):
    payload = json.dumps(
        wf.get("connections", {}),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()

print("main_candidate_created=", main_dst)
print("photo_candidate_created=", photo_dst)
print("main_nodes=", len(main_after["nodes"]))
print("photo_nodes=", len(photo_after["nodes"]))
print("main_graph_sha256=", graph_hash(main_after))
print("photo_graph_sha256=", graph_hash(photo_after))
print("status=PASS")
