#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_GENERATOR = ROOT / 'scripts/spc001-generate-financial-api.py'


def load_base():
    spec = importlib.util.spec_from_file_location('spc001_financial_generator', BASE_GENERATOR)
    if spec is None or spec.loader is None:
        raise SystemExit('ERROR: cannot load SPC-001 financial generator')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BASE = load_base()

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


def build(credential_id: str, credential_name: str) -> dict:
    original_routes = BASE.ROUTES
    original_sql_query = BASE.sql_query
    try:
        BASE.ROUTES = ROUTES
        BASE.sql_query = sql_query
        workflow = BASE.build(credential_id, credential_name)
    finally:
        BASE.ROUTES = original_routes
        BASE.sql_query = original_sql_query

    # Runtime cutover replaces the accepted financial workflow in place rather
    # than creating a second owner for the same webhook paths.
    if workflow.get('id') != 'SPC001FinancialApi202608':
        raise SystemExit('ERROR: financial workflow identity changed')
    workflow['name'] = 'MoneyTrack UX-025 Financial API'
    workflow['active'] = False
    return workflow


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--postgres-credential-id', default='tM27zg5m7tREo2ep')
    parser.add_argument('--postgres-credential-name', default='Postgres account')
    args = parser.parse_args()

    workflow = build(args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    print(f"workflow={workflow['id']} routes={len(ROUTES)} nodes={len(workflow['nodes'])} path={args.output}")
    for method, path in ROUTES:
        print(f"UX025_FINANCIAL {method} /{path}")


if __name__ == '__main__':
    main()
