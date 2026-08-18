#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_PATH = ROOT / 'scripts/spc001-generate-financial-api.py'
UX_PATH = ROOT / 'scripts/ux025-generate-financial-api.py'
SEC_PATH = ROOT / 'scripts/sec001-build-live-candidates.py'
WORKFLOW_ID = 'SPC001FinancialApi202608'


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f'UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL cannot_load={path}')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_workflow(path: Path) -> dict:
    raw = json.loads(path.read_text(encoding='utf-8'))
    if isinstance(raw, list):
        if len(raw) != 1 or not isinstance(raw[0], dict):
            raise SystemExit('UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL export_shape')
        return raw[0]
    if not isinstance(raw, dict):
        raise SystemExit('UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL export_shape')
    return raw


def route_set(workflow: dict) -> set[tuple[str, str]]:
    result: set[tuple[str, str]] = set()
    for node in workflow.get('nodes') or []:
        if node.get('type') != 'n8n-nodes-base.webhook':
            continue
        params = node.get('parameters') or {}
        route = (
            str(params.get('httpMethod') or 'GET').upper(),
            str(params.get('path') or '').lstrip('/'),
        )
        if route in result:
            raise SystemExit(f'UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL duplicate_route={route}')
        result.add(route)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--expected', choices=('spc', 'ux025'), required=True)
    parser.add_argument(
        '--protection',
        choices=('required', 'observe'),
        default='required',
        help='observe reports a pre-existing SEC gap without accepting it as protected runtime',
    )
    args = parser.parse_args()

    base = load_module(BASE_PATH, 'ux025_verify_base')
    ux = load_module(UX_PATH, 'ux025_verify_candidate')
    sec = load_module(SEC_PATH, 'ux025_verify_sec')
    workflow = load_workflow(args.input)

    if workflow.get('id') != WORKFLOW_ID:
        raise SystemExit(f"UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL id={workflow.get('id')}")

    expected = set(base.ROUTES if args.expected == 'spc' else ux.ROUTES)
    actual = route_set(workflow)
    if actual != expected:
        raise SystemExit(
            'UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL route_drift '
            f'missing={sorted(expected-actual)} extra={sorted(actual-expected)}'
        )

    # Accepted runtime always requires SEC Class-B protection. The observe mode
    # exists only to classify a forensic pre-cutover export before repairing it;
    # it must never be used to validate a candidate, post-state, or rollback.
    protection = 'PASS'
    protection_detail = ''
    try:
        sec.verify_protected_api(workflow)
    except SystemExit as exc:
        if args.protection != 'observe':
            raise
        protection = 'GAP'
        protection_detail = str(exc)

    backend_nodes = [
        n for n in workflow.get('nodes') or []
        if n.get('type') == 'n8n-nodes-base.postgres'
        and str(n.get('name') or '').endswith(' Backend')
    ]
    if len(backend_nodes) != len(expected):
        raise SystemExit(
            f'UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL backend_count={len(backend_nodes)} expected={len(expected)}'
        )

    queries = [str((n.get('parameters') or {}).get('query') or '') for n in backend_nodes]
    dispatcher = (
        'moneytrack.spc001_financial_api_dispatch_v1('
        if args.expected == 'spc'
        else 'moneytrack.ux025_financial_api_dispatch_v1('
    )
    if not all(dispatcher in query for query in queries):
        raise SystemExit('UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL dispatcher_drift')

    category_routes = sorted(route for route in actual if route[1] == 'api/v1/categories')
    expected_category = (
        [('PATCH', 'api/v1/categories')]
        if args.expected == 'spc'
        else [
            ('DELETE', 'api/v1/categories'),
            ('GET', 'api/v1/categories'),
            ('PATCH', 'api/v1/categories'),
            ('POST', 'api/v1/categories'),
        ]
    )
    if category_routes != expected_category:
        raise SystemExit(f'UX025_FINANCIAL_WORKFLOW_VERIFY=FAIL category_routes={category_routes}')

    print(f'UX025_FINANCIAL_WORKFLOW_ID=PASS id={WORKFLOW_ID}')
    print(f'UX025_FINANCIAL_ROUTE_SET=PASS expected={args.expected} routes={len(actual)}')
    if protection == 'PASS':
        print(f'UX025_FINANCIAL_SEC001_PROTECTION=PASS routes={len(actual)}')
    else:
        print(f'UX025_FINANCIAL_SEC001_PROTECTION=GAP detail={protection_detail}')
    print(f'UX025_FINANCIAL_DISPATCHER=PASS expected={args.expected}')
    print('UX025_FINANCIAL_WORKFLOW_VERIFY=PASS')


if __name__ == '__main__':
    main()
