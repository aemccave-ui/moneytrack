#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
import uuid
from pathlib import Path

NS = uuid.UUID('d8c67f78-8d22-4d31-96d4-6d82af5cf75f')


def load_one(path: Path) -> tuple[dict, bool]:
    raw = json.loads(path.read_text(encoding='utf-8'))
    if isinstance(raw, list):
        if len(raw) != 1:
            raise SystemExit(f'expected one workflow in {path}, got {len(raw)}')
        return raw[0], True
    if isinstance(raw, dict):
        return raw, False
    raise SystemExit(f'invalid workflow document: {path}')


def write_one(path: Path, workflow: dict, wrapped: bool) -> None:
    payload = [workflow] if wrapped else workflow
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def node_by_name(workflow: dict, name: str) -> dict:
    matches = [n for n in workflow.get('nodes', []) if n.get('name') == name]
    if len(matches) != 1:
        raise SystemExit(f'expected exactly one node {name!r}, found {len(matches)}')
    return matches[0]


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


PHOTO_HASH_CODE = r'''const item = $input.first();
if (item.json?.ok === false) return [item];
const binary = item.binary || {};
const keys = Object.keys(binary);
if (!keys.length) {
  return [{ json:{ ok:false, http_status:400, error:{ code:'PHOTO_BINARY_MISSING' } } }];
}
const crypto = require('crypto');
const buffer = await this.helpers.getBinaryDataBuffer(0, keys[0]);
const digest = crypto.createHash('sha256').update(buffer).digest('hex');
return [{
  json: {
    ...item.json,
    photo_sha256: digest,
    photo_identity: `miniapp-sha256:${digest}`
  },
  binary
}];'''

PHOTO_FORMAT_CODE = r'''const row = $input.first().json || {};
if (row.success === false && (row.status === 'duplicate_exact' || row.status === 'duplicate_semantic')) {
  const exact = row.status === 'duplicate_exact';
  const code = exact ? 'RECEIPT_DUPLICATE_EXACT' : 'RECEIPT_DUPLICATE_SEMANTIC';
  const fallback = exact
    ? 'Этот чек уже был загружен. Повторная операция не создана.'
    : 'Похожий чек уже учтён. Повторная операция не создана.';
  return [{
    json: {
      ok: false,
      http_status: 409,
      error: {
        code,
        message: String(row.message || fallback)
      }
    }
  }];
}
if (row.error) {
  const raw = String(row.error?.message || row.error || 'DOMAIN_ERROR');
  const match = raw.match(/\b([A-Z][A-Z0-9_]+)\b/);
  return [{ json:{ ok:false, http_status:400, error:{ code:match ? match[1] : 'DOMAIN_ERROR' } } }];
}
return [{ json:{ ok:true, http_status:200, data:row } }];'''

EXACT_QUERY = r'''select exists(
  select 1
  from moneytrack.receipts r
  where r.user_id = {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint
    and r.telegram_file_id = nullif('{{ String($json.telegram_file_id || "").replace(/'/g, "''") }}','')
) as duplicate_found;'''

SEMANTIC_QUERY = r'''with parsed as (
    select
        nullif(
            nullif(
                nullif('{{ String($('Parse receipt JSON').first().json.receipt_date || "").replace(/'/g,"''") }}',''),
                'null'
            ),
            'undefined'
        )::date as receipt_date,
        {{ Number($('Parse receipt JSON').first().json.total_amount || 0) }}::numeric as total_amount,
        upper('{{ String($('Parse receipt JSON').first().json.currency || "").replace(/'/g,"''") }}')::text as currency,
        $json${{ JSON.stringify(Array.isArray($('Parse receipt JSON').first().json.items) ? $('Parse receipt JSON').first().json.items : []) }}$json$::jsonb as items,
        nullif(
            '{{ String($('Build receipt fingerprint').first().json.receipt_fingerprint || "").replace(/'/g,"''") }}',
            ''
        )::text as legacy_fingerprint
),
input_signature as (
    select
        count(e.value)::integer as item_count,
        coalesce(
            array_agg(
                round(
                    case
                        when nullif(e.value->>'amount','') is not null
                            then (e.value->>'amount')::numeric
                        else coalesce(nullif(e.value->>'quantity','')::numeric, 1)
                             * coalesce(
                                 nullif(e.value->>'unit_price','')::numeric,
                                 nullif(e.value->>'price','')::numeric,
                                 0
                               )
                    end,
                    2
                )
                order by round(
                    case
                        when nullif(e.value->>'amount','') is not null
                            then (e.value->>'amount')::numeric
                        else coalesce(nullif(e.value->>'quantity','')::numeric, 1)
                             * coalesce(
                                 nullif(e.value->>'unit_price','')::numeric,
                                 nullif(e.value->>'price','')::numeric,
                                 0
                               )
                    end,
                    2
                )
            ) filter (where e.value is not null),
            array[]::numeric[]
        ) as amount_signature
    from parsed p
    left join lateral jsonb_array_elements(p.items) e(value) on true
),
candidates as (
    select
        r.id,
        r.receipt_fingerprint,
        count(ri.id)::integer as item_count,
        coalesce(
            array_agg(round(ri.amount, 2) order by round(ri.amount, 2))
                filter (where ri.id is not null),
            array[]::numeric[]
        ) as amount_signature
    from moneytrack.receipts r
    left join moneytrack.receipt_items ri
      on ri.receipt_id = r.id
    cross join parsed p
    where r.user_id = {{ $('MoneyTrack Transaction Processor Photo').first().json.user_id }}::bigint
      and r.receipt_date is not distinct from p.receipt_date
      and r.total_amount = p.total_amount
      and upper(r.currency) = p.currency
    group by r.id, r.receipt_fingerprint
)
select exists(
    select 1
    from candidates c
    cross join input_signature i
    cross join parsed p
    where (
        p.legacy_fingerprint is not null
        and c.receipt_fingerprint = p.legacy_fingerprint
    ) or (
        c.item_count = i.item_count
        and c.amount_signature = i.amount_signature
    )
) as semantic_duplicate_found;'''


def patch_quick(workflow: dict) -> dict:
    wf = copy.deepcopy(workflow)
    if str(wf.get('id')) != 'UX022QuickInput202608':
        raise SystemExit(f'unexpected quick workflow id: {wf.get("id")}')

    names = {n.get('name') for n in wf.get('nodes', [])}
    if 'Photo Hash' in names:
        raise SystemExit('Photo Hash already present; refuse double patch')

    auth_ok = node_by_name(wf, 'Photo Auth OK')
    user_context = node_by_name(wf, 'Photo User Context')
    prepare = node_by_name(wf, 'Photo Prepare')
    photo_format = node_by_name(wf, 'Photo Format')

    pos = auth_ok.get('position') or [-470, -360]
    hash_node = {
        'parameters': {'jsCode': PHOTO_HASH_CODE},
        'type': 'n8n-nodes-base.code',
        'typeVersion': 2,
        'position': [int(pos[0]) + 120, int(pos[1]) - 70],
        'id': uid('Photo Hash'),
        'name': 'Photo Hash',
    }
    wf.setdefault('nodes', []).append(hash_node)

    conns = wf.setdefault('connections', {})
    auth_main = conns.get('Photo Auth OK', {}).get('main')
    if not auth_main or len(auth_main) < 1:
        raise SystemExit('Photo Auth OK connections missing')
    true_branch = auth_main[0] or []
    if len(true_branch) != 1 or true_branch[0].get('node') != 'Photo User Context':
        raise SystemExit(f'unexpected Photo Auth OK true branch: {true_branch}')
    true_branch[0]['node'] = 'Photo Hash'
    conns['Photo Hash'] = {'main': [[{'node': 'Photo User Context', 'type': 'main', 'index': 0}]]}

    prepare_code = prepare.get('parameters', {}).get('jsCode', '')
    needle = '    telegram_chat_id: null,\n'
    addition = "    telegram_file_id: $('Photo Hash').first().json.photo_identity,\n"
    if needle not in prepare_code:
        raise SystemExit('Photo Prepare insertion point missing')
    prepare['parameters']['jsCode'] = prepare_code.replace(needle, needle + addition, 1)
    photo_format.setdefault('parameters', {})['jsCode'] = PHOTO_FORMAT_CODE

    user_context['position'] = [int(pos[0]) + 320, int(pos[1]) - 70]
    prepare['position'] = [int(pos[0]) + 540, int(pos[1]) - 70]
    return wf


def patch_photo(workflow: dict) -> dict:
    wf = copy.deepcopy(workflow)
    if str(wf.get('id')) != '5VC0EcFB21rwTfoI':
        raise SystemExit(f'unexpected photo workflow id: {wf.get("id")}')
    exact = node_by_name(wf, 'Check duplicate receipt')
    semantic = node_by_name(wf, 'Check semantic duplicate receipt')
    if exact.get('type') != 'n8n-nodes-base.postgres' or semantic.get('type') != 'n8n-nodes-base.postgres':
        raise SystemExit('dedup nodes are not Postgres nodes')
    exact.setdefault('parameters', {})['query'] = EXACT_QUERY + '\n'
    semantic.setdefault('parameters', {})['query'] = SEMANTIC_QUERY + '\n'
    return wf


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--quick-before', type=Path, required=True)
    parser.add_argument('--photo-before', type=Path, required=True)
    parser.add_argument('--quick-after', type=Path, required=True)
    parser.add_argument('--photo-after', type=Path, required=True)
    args = parser.parse_args()

    quick, quick_wrapped = load_one(args.quick_before)
    photo, photo_wrapped = load_one(args.photo_before)
    quick_after = patch_quick(quick)
    photo_after = patch_photo(photo)
    write_one(args.quick_after, quick_after, quick_wrapped)
    write_one(args.photo_after, photo_after, photo_wrapped)

    print(f'quick_nodes_before={len(quick.get("nodes", []))}')
    print(f'quick_nodes_after={len(quick_after.get("nodes", []))}')
    print(f'photo_nodes={len(photo_after.get("nodes", []))}')
    print('PHOTO_DEDUP_PATCH=PASS')


if __name__ == '__main__':
    main()
