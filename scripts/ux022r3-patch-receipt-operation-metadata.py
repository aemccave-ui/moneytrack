#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

NODE_NAME = 'Update product category'

QUERY = r"""
with assigned as (
    select *
    from moneytrack.receipt_assign_categories_v1(
        {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
        {{ $('Insert receipt').first().json.id }}::bigint,
        $json${{ JSON.stringify($json.assignments || []) }}$json$::jsonb
    )
),
finalized as (
    select *
    from moneytrack.receipt_finalize_transaction_metadata_v1(
        {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint,
        {{ $('Insert receipt').first().json.id }}::bigint,
        nullif(
            '{{ String((() => {
                const receipt = $('Parse receipt JSON').first().json || {};
                const explicit = receipt.receipt_time || receipt.time || '';
                if (explicit) return explicit;
                const raw = String(receipt.receipt_datetime || receipt.receipt_date || '');
                const match = raw.match(/(?:T|\s)(\d{1,2}:\d{2}(?::\d{2})?)/);
                return match ? match[1] : '';
            })()).replace(/'/g,"''") }}',
            ''
        )::text,
        {{ $('MoneyTrack Transaction Processor Photo').first().json.message_date || 'null' }}::bigint
    )
)
select
    a.updated_product_count as updated_count,
    a.updated_item_count,
    a.status,
    f.transaction_id,
    f.transaction_date,
    f.category_id as transaction_category_id,
    f.category_status,
    f.time_status
from assigned a
cross join finalized f;
""".strip() + '\n'


def load(path: Path):
    data = json.loads(path.read_text(encoding='utf-8'))
    if isinstance(data, list):
        if len(data) != 1:
            raise SystemExit(f'ERROR: expected one workflow in {path}')
        return data, data[0]
    if isinstance(data, dict):
        return data, data
    raise SystemExit(f'ERROR: invalid workflow document {path}')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()

    document, workflow = load(args.source)
    target = [node for node in workflow.get('nodes', []) if node.get('name') == NODE_NAME]
    if len(target) != 1:
        raise SystemExit(f'ERROR: expected one {NODE_NAME!r} node, found {len(target)}')
    if target[0].get('type') != 'n8n-nodes-base.postgres':
        raise SystemExit(f'ERROR: {NODE_NAME!r} is not Postgres')

    out = copy.deepcopy(document)
    out_workflow = out[0] if isinstance(out, list) else out
    out_target = [node for node in out_workflow['nodes'] if node.get('name') == NODE_NAME][0]
    out_target.setdefault('parameters', {})['query'] = QUERY

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(out, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'receipt_metadata_candidate={args.output}')
    print('receipt_time_fields=receipt_time,time,receipt_datetime,receipt_date-with-time')
    print('receipt_category_rule=single-classified-category-only')
    print('status=PASS')


if __name__ == '__main__':
    main()
