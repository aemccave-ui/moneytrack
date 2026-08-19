#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_GENERATOR = ROOT / 'scripts/spc001-generate-financial-api.py'
SEC_BUILDER = ROOT / 'scripts/sec001-build-live-candidates.py'


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f'ERROR: cannot load {path.name}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BASE = load_module(BASE_GENERATOR, 'spc001_financial_generator')
SEC = load_module(SEC_BUILDER, 'ux025_sec_runtime_builder')

# Preserve every accepted SPC-001 route and add only missing category CRUD
# methods on the already-owned /api/v1/categories path.
ROUTES = []
for method, path in BASE.ROUTES:
    if (method, path) == ('PATCH', 'api/v1/categories'):
        ROUTES.extend([
            ('GET', 'api/v1/categories'),
            ('POST', 'api/v1/categories'),
            ('PATCH', 'api/v1/categories'),
            ('DELETE', 'api/v1/categories'),
        ])
    else:
        ROUTES.append((method, path))

if len(ROUTES) != len(BASE.ROUTES) + 3:
    raise SystemExit('ERROR: UX-025 route extension is not exactly +3')


def sql_query(method: str, path: str) -> str:
    return f"""select moneytrack.ux025_financial_api_dispatch_v1(
  {{{{ $json.telegram_user_id }}}}::bigint,
  {{{{ $json.space_id }}}}::bigint,
  '{method}'::text,
  '{path}'::text,
  '{{{{ JSON.stringify($json.query || {{}}).replaceAll("'", "''") }}}}'::jsonb,
  '{{{{ JSON.stringify($json.body || {{}}).replaceAll("'", "''") }}}}'::jsonb
) as data;"""


def secure(workflow: dict) -> dict:
    secured = SEC.transform_api(workflow)
    SEC.verify_protected_api(secured)
    if secured.get('id') != 'SPC001FinancialApi202608':
        raise SystemExit('ERROR: SEC transform changed workflow identity')
    secured['active'] = False
    return secured


def build(credential_id: str, credential_name: str) -> dict:
    original_routes = BASE.ROUTES
    original_sql_query = BASE.sql_query
    try:
        BASE.ROUTES = ROUTES
        BASE.sql_query = sql_query
        raw = BASE.build(credential_id, credential_name)
    finally:
        BASE.ROUTES = original_routes
        BASE.sql_query = original_sql_query

    if raw.get('id') != 'SPC001FinancialApi202608':
        raise SystemExit('ERROR: financial workflow identity changed')

    # Every Financial API route is SEC-001 Class B. Apply the canonical SEC
    # graph transform after extending the route set; importing the raw SPC
    # generator output would otherwise remove unlock enforcement from the
    # existing financial workflow during replacement.
    workflow = secure(raw)
    workflow['name'] = 'MoneyTrack UX-025 Financial API'
    return workflow


def build_spc_secured(credential_id: str, credential_name: str) -> dict:
    """Canonical protected SPC-001 fallback used only for UX-025 rollback.

    Do not restore a forensic pre-cutover export when that export has lost its
    SEC-001 Class-B boundary. Rebuild the accepted 30-route SPC workflow from
    source and apply the canonical SEC transform before any UX-025 mutation.
    """
    raw = BASE.build(credential_id, credential_name)
    if raw.get('id') != 'SPC001FinancialApi202608':
        raise SystemExit('ERROR: SPC rollback workflow identity changed')
    workflow = secure(raw)
    workflow['name'] = 'MoneyTrack SPC-001 Financial API (SEC rollback)'
    return workflow


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=('ux025', 'spc-secured'), default='ux025')
    parser.add_argument('--postgres-credential-id', default='tM27zg5m7tREo2ep')
    parser.add_argument('--postgres-credential-name', default='Postgres account')
    args = parser.parse_args()

    workflow = (
        build(args.postgres_credential_id, args.postgres_credential_name)
        if args.mode == 'ux025'
        else build_spc_secured(args.postgres_credential_id, args.postgres_credential_name)
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    route_count = len(ROUTES) if args.mode == 'ux025' else len(BASE.ROUTES)
    print(f"workflow={workflow['id']} mode={args.mode} routes={route_count} nodes={len(workflow['nodes'])} path={args.output}")
    print('SEC001_FINANCIAL_PROTECTION=PASS')
    routes = ROUTES if args.mode == 'ux025' else BASE.ROUTES
    for method, path in routes:
        print(f"UX025_FINANCIAL {method} /{path}")


if __name__ == '__main__':
    main()
