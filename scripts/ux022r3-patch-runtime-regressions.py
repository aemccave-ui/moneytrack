#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path


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
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps([workflow] if wrapped else workflow, ensure_ascii=False, indent=2) + '\n',
        encoding='utf-8',
    )


def node_by_name(workflow: dict, name: str) -> dict:
    rows = [n for n in workflow.get('nodes', []) if n.get('name') == name]
    if len(rows) != 1:
        raise SystemExit(f'expected exactly one node {name!r}, found {len(rows)}')
    return rows[0]


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
      error: { code, message: String(row.message || fallback) }
    }
  }];
}
if (row.error) {
  const raw = String(row.error?.message || row.error || '');
  const match = raw.match(/\b([A-Z][A-Z0-9_]+)\b/);
  const code = match ? match[1] : 'PHOTO_PROCESSOR_ERROR';
  const friendly = code === 'PHOTO_PROCESSOR_ERROR'
    ? 'Не удалось обработать чек. Попробуйте загрузить фото ещё раз.'
    : raw;
  return [{ json:{ ok:false, http_status:400, error:{ code, message:friendly } } }];
}
return [{ json:{ ok:true, http_status:200, data:row } }];'''


def patch_quick(workflow: dict) -> dict:
    wf = copy.deepcopy(workflow)
    if str(wf.get('id')) != 'UX022QuickInput202608':
        raise SystemExit(f'unexpected quick workflow id: {wf.get("id")}')

    node_by_name(wf, 'Photo Hash')
    prepare = node_by_name(wf, 'Photo Prepare')
    fmt = node_by_name(wf, 'Photo Format')

    code = prepare.get('parameters', {}).get('jsCode', '')
    old = "    telegram_file_id: $('Photo Hash').first().json.photo_identity,"
    new = "    receipt_source_identity: $('Photo Hash').first().json.photo_identity,"
    if old not in code:
        raise SystemExit('quick runtime is not in the expected synthetic-telegram-file-id state')
    if 'receipt_source_identity:' in code:
        raise SystemExit('quick runtime already contains receipt_source_identity')
    prepare['parameters']['jsCode'] = code.replace(old, new, 1)
    fmt.setdefault('parameters', {})['jsCode'] = PHOTO_FORMAT_CODE
    return wf


def patch_photo(workflow: dict) -> dict:
    wf = copy.deepcopy(workflow)
    if str(wf.get('id')) != '5VC0EcFB21rwTfoI':
        raise SystemExit(f'unexpected photo workflow id: {wf.get("id")}')

    exact = node_by_name(wf, 'Check duplicate receipt')
    exact_query = exact.get('parameters', {}).get('query', '')
    old_exact = 'String($json.telegram_file_id || "")'
    new_exact = 'String($json.receipt_source_identity || $json.telegram_file_id || "")'
    if old_exact not in exact_query:
        raise SystemExit('exact dedup query is not in expected patched state')
    exact['parameters']['query'] = exact_query.replace(old_exact, new_exact, 1)

    trigger_ref = "$('MoneyTrack Transaction Processor Photo').first().json.telegram_file_id"
    replacement = (
        "($('MoneyTrack Transaction Processor Photo').first().json.receipt_source_identity || "
        "$('MoneyTrack Transaction Processor Photo').first().json.telegram_file_id)"
    )
    patched_ingest_nodes = 0
    for n in wf.get('nodes', []):
        params = n.get('parameters') or {}
        query = params.get('query')
        if not isinstance(query, str) or 'receipt_ingest_v1' not in query:
            continue
        if trigger_ref not in query:
            raise SystemExit(f'receipt_ingest_v1 node {n.get("name")!r} lacks canonical telegram_file_id reference')
        params['query'] = query.replace(trigger_ref, replacement)
        patched_ingest_nodes += 1

    if patched_ingest_nodes < 1:
        raise SystemExit('receipt_ingest_v1 node not found in photo workflow')

    return wf


def patch_dashboard(workflow: dict) -> dict:
    wf = copy.deepcopy(workflow)
    replacements = 0
    for n in wf.get('nodes', []):
        params = n.get('parameters') or {}
        for key in ('query', 'jsCode'):
            value = params.get(key)
            if not isinstance(value, str) or 'finance_dashboard_read_model_v1' not in value:
                continue
            params[key] = value.replace('finance_dashboard_read_model_v1', 'finance_dashboard_read_model_v2')
            replacements += 1
    if replacements != 1:
        raise SystemExit(f'expected exactly one dashboard v1 adapter reference, patched={replacements}')
    return wf


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--quick-before', type=Path, required=True)
    p.add_argument('--photo-before', type=Path, required=True)
    p.add_argument('--dashboard-before', type=Path, required=True)
    p.add_argument('--quick-after', type=Path, required=True)
    p.add_argument('--photo-after', type=Path, required=True)
    p.add_argument('--dashboard-after', type=Path, required=True)
    args = p.parse_args()

    quick, quick_wrapped = load_one(args.quick_before)
    photo, photo_wrapped = load_one(args.photo_before)
    dashboard, dashboard_wrapped = load_one(args.dashboard_before)

    q2 = patch_quick(quick)
    p2 = patch_photo(photo)
    d2 = patch_dashboard(dashboard)

    write_one(args.quick_after, q2, quick_wrapped)
    write_one(args.photo_after, p2, photo_wrapped)
    write_one(args.dashboard_after, d2, dashboard_wrapped)

    print('quick_photo_identity_separated_from_telegram_file_id=PASS')
    print('photo_exact_dedup_identity=PASS')
    print('photo_receipt_ingest_identity_persistence=PASS')
    print('photo_friendly_processor_error=PASS')
    print('dashboard_adapter_v2=PASS')
    print('UX022R3_RUNTIME_REGRESSION_PATCH=PASS')


if __name__ == '__main__':
    main()
