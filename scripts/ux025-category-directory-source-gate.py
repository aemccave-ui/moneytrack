#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOMAIN = (ROOT / 'db/domain/UX-025/010_space_category_directory.sql').read_text(encoding='utf-8')
REORDER = (ROOT / 'db/domain/UX-025/015_space_category_reorder.sql').read_text(encoding='utf-8')
DISPATCH = (ROOT / 'db/domain/UX-025/020_category_api_dispatch.sql').read_text(encoding='utf-8')
GENERATOR = ROOT / 'scripts/ux025-generate-financial-api.py'
VERIFIER = ROOT / 'scripts/ux025-verify-financial-workflow.py'
N8N_APPLY = ROOT / 'scripts/ux025-n8n-runtime-apply.sh'
BASE_GENERATOR = ROOT / 'scripts/spc001-generate-financial-api.py'
DESIGN = (ROOT / 'docs/architecture/UX-025-settings-category-directory.md').read_text(encoding='utf-8')
N8N_APPLY_TEXT = N8N_APPLY.read_text(encoding='utf-8')


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f'cannot load {path}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


checks: dict[str, bool] = {}

checks['ux025_design_declares_space_owned_directory'] = all(x in DESIGN for x in (
    'Categories become a full mutable Space-owned directory',
    'CATEGORY_SAME_SPACE_GUARD=PASS',
    'CATEGORY_HISTORY_PRESERVED=PASS',
    'CATEGORY_SPACE_ISOLATION=PASS',
))

checks['ux025_category_read_is_space_scoped'] = all(x in DOMAIN for x in (
    'category_directory_space_v1',
    'assert_space_member_v1(p_actor_user_id, p_space_id)',
    'c.space_id = p_space_id',
    "coalesce(c.is_active, true) = true",
))

checks['ux025_category_create_is_space_owned_and_flow_fail_closed'] = all(x in DOMAIN for x in (
    'category_create_space_v1',
    'user_id,',
    'space_id,',
    'created_by_user_id,',
    'updated_by_user_id',
    'p_actor_user_id,',
    'p_space_id,',
    "if v_flow is null or v_flow not in ('income', 'expense') then",
    "'CATEGORY_PARENT_NOT_FOUND_IN_SPACE'",
))

checks['ux025_category_edit_has_same_space_cycle_and_flow_guards'] = all(x in DOMAIN for x in (
    'category_edit_space_v1',
    "if v_flow is null or v_flow not in ('income', 'expense') then",
    "'CATEGORY_PARENT_CYCLE'",
    'with recursive descendants(id)',
    'c.space_id = p_space_id',
    "'CATEGORY_PARENT_NOT_FOUND_IN_SPACE'",
))

checks['ux025_category_reorder_is_atomic_sibling_move'] = all(x in REORDER for x in (
    'drop function if exists moneytrack.category_reorder_space_v1(bigint,bigint,bigint,integer)',
    'category_reorder_space_v1(',
    "if v_direction is null or v_direction not in ('up', 'down') then",
    'array_agg(c.id order by coalesce(c.sort_order, 0), c.id)',
    'array_position(v_ids, p_category_id)',
    'v_ids[v_index] := v_ids[v_target]',
    'set sort_order = v_i * 10',
    'pg_advisory_xact_lock',
    'c.space_id = p_space_id',
    "'reordered'::text",
))

checks['ux025_delete_is_history_safe_archive'] = all(x in DOMAIN for x in (
    'category_delete_space_v1',
    "'CATEGORY_HAS_ACTIVE_CHILDREN'",
    'set is_active = false',
    "'archived'::text",
    'Never physically remove historical category ids',
)) and 'delete from moneytrack.category_catalog' not in DOMAIN.lower()

checks['ux025_dispatch_delegates_non_category_routes'] = all(x in DISPATCH for x in (
    "if v_path <> 'api/v1/categories' then",
    'return moneytrack.spc001_financial_api_dispatch_v1(',
    'spc001_resolve_actor_user_id_v1',
    'assert_space_member_v1(v_actor, p_space_id)',
))

checks['ux025_dispatch_owns_category_crud_methods'] = all(x in DISPATCH for x in (
    "if v_method = 'GET' then",
    'category_directory_space_v1',
    "if v_method = 'POST' then",
    'category_create_space_v1',
    "if v_method = 'PATCH' then",
    'category_edit_space_v1',
    "lower(coalesce(v_body->>'action', '')) = 'reorder'",
    "v_body->>'direction'",
    'category_reorder_space_v1',
    "if v_method = 'DELETE' then",
    'category_delete_space_v1',
))

checks['ux025_n8n_recovery_never_rolls_back_to_forensic_prestate'] = all(x in N8N_APPLY_TEXT for x in (
    'financial.before.published.json',
    'financial.rollback.secured.json',
    '--mode spc-secured',
    'import_publish "$ROLLBACK_SECURED"',
    'ROLLBACK_CANDIDATE_SEC001=PASS',
    'PRE_SEC001_PROTECTION=',
)) and 'import_publish "$OLD_PUBLISHED"' not in N8N_APPLY_TEXT

checks['ux025_n8n_db_evidence_reuse_is_fail_closed'] = all(x in N8N_APPLY_TEXT for x in (
    'git merge-base --is-ancestor "$DB_EVIDENCE_HEAD" "$HEAD_SHA"',
    'git diff --quiet "$DB_EVIDENCE_HEAD" "$HEAD_SHA"',
    'db/domain/UX-025',
    'scripts/ux025-build-db-bundle.py',
    'scripts/ux025-db-runtime-apply.sh',
    'db_source_changed_since_evidence',
))

checks['ux025_n8n_import_staging_root_safe'] = all(x in N8N_APPLY_TEXT for x in (
    'docker exec -u 0 "$N8N_CONTAINER" rm -f "$remote"',
    'docker exec -u 0 "$N8N_CONTAINER" chmod 0644 "$remote"',
)) and 'docker exec "$N8N_CONTAINER" chmod 0644 "$remote"' not in N8N_APPLY_TEXT

try:
    base = load_module(BASE_GENERATOR, 'ux025_base_financial_generator')
    ux025 = load_module(GENERATOR, 'ux025_financial_generator')
    checks['ux025_frozen_spc_generator_shape_preserved'] = (
        len(base.ROUTES) == 30
        and [x for x in base.ROUTES if x[1] == 'api/v1/categories'] == [('PATCH', 'api/v1/categories')]
    )
    checks['ux025_candidate_route_shape'] = (
        len(ux025.ROUTES) == 33
        and [x for x in ux025.ROUTES if x[1] == 'api/v1/categories'] == [
            ('GET', 'api/v1/categories'),
            ('POST', 'api/v1/categories'),
            ('PATCH', 'api/v1/categories'),
            ('DELETE', 'api/v1/categories'),
        ]
    )
except Exception:
    checks['ux025_frozen_spc_generator_shape_preserved'] = False
    checks['ux025_candidate_route_shape'] = False

try:
    with tempfile.TemporaryDirectory(prefix='ux025-category-source-') as tmp:
        output = Path(tmp) / 'financial.json'
        subprocess.run(
            [sys.executable, str(GENERATOR), '--output', str(output)],
            check=True,
            cwd=ROOT,
            stdout=subprocess.DEVNULL,
        )
        workflow = json.loads(output.read_text(encoding='utf-8'))
    nodes = workflow.get('nodes', [])
    backend_nodes = [
        n for n in nodes
        if n.get('type') == 'n8n-nodes-base.postgres'
        and str(n.get('name', '')).endswith(' Backend')
    ]
    webhook_nodes = [n for n in nodes if n.get('type') == 'n8n-nodes-base.webhook']
    backend_queries = [str((n.get('parameters') or {}).get('query') or '') for n in backend_nodes]
    unlock_prepare = [n for n in nodes if str(n.get('name', '')).startswith('SEC001 Unlock Prepare [')]
    unlock_verify = [n for n in nodes if str(n.get('name', '')).startswith('SEC001 Unlock Verify [')]
    unlock_decision = [n for n in nodes if str(n.get('name', '')).startswith('SEC001 Unlock Decision [')]
    unlock_ok = [n for n in nodes if str(n.get('name', '')).startswith('SEC001 Unlock OK [')]
    unlock_reject = [n for n in nodes if str(n.get('name', '')).startswith('SEC001 Unlock Reject [')]
    names = {str(n.get('name', '')) for n in nodes}
    category_sec_markers = {
        f'SEC001 Unlock Prepare [{method} api/v1/categories]'
        for method in ('GET', 'POST', 'PATCH', 'DELETE')
    }
    checks['ux025_candidate_identity_preserved'] = workflow.get('id') == 'SPC001FinancialApi202608'
    checks['ux025_candidate_has_single_owner_per_route'] = len(webhook_nodes) == 33 and len(backend_nodes) == 33
    checks['ux025_candidate_calls_wrapper_only'] = bool(backend_queries) and all(
        'moneytrack.ux025_financial_api_dispatch_v1(' in query for query in backend_queries
    )
    checks['ux025_candidate_all_financial_routes_sec_protected'] = all(
        len(group) == 33
        for group in (unlock_prepare, unlock_verify, unlock_decision, unlock_ok, unlock_reject)
    )
    checks['ux025_category_crud_routes_sec_protected'] = category_sec_markers <= names
    checks['ux025_candidate_stays_inactive_in_source'] = workflow.get('active') is False
except Exception:
    checks['ux025_candidate_identity_preserved'] = False
    checks['ux025_candidate_has_single_owner_per_route'] = False
    checks['ux025_candidate_calls_wrapper_only'] = False
    checks['ux025_candidate_all_financial_routes_sec_protected'] = False
    checks['ux025_category_crud_routes_sec_protected'] = False
    checks['ux025_candidate_stays_inactive_in_source'] = False

try:
    subprocess.run(['bash', '-n', str(N8N_APPLY)], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, '-m', 'py_compile', str(VERIFIER)], check=True, cwd=ROOT, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix='ux025-sec-recovery-') as tmp:
        secured = Path(tmp) / 'spc-secured.json'
        ux_candidate = Path(tmp) / 'ux025.json'
        subprocess.run(
            [sys.executable, str(GENERATOR), '--mode', 'spc-secured', '--output', str(secured)],
            check=True, cwd=ROOT, stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [sys.executable, str(VERIFIER), '--input', str(secured), '--expected', 'spc'],
            check=True, cwd=ROOT, stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [sys.executable, str(GENERATOR), '--mode', 'ux025', '--output', str(ux_candidate)],
            check=True, cwd=ROOT, stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [sys.executable, str(VERIFIER), '--input', str(ux_candidate), '--expected', 'ux025'],
            check=True, cwd=ROOT, stdout=subprocess.DEVNULL,
        )
    checks['ux025_secured_recovery_candidate_gate'] = True
except Exception:
    checks['ux025_secured_recovery_candidate_gate'] = False

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"UX025_CATEGORY_DIRECTORY_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print('RUNTIME_EVIDENCE=NOT_CLAIMED')
print('DB_MUTATION=NONE')
print('N8N_MUTATION=NONE')
print('PREVIEW_MUTATION=NONE')
print('PRODUCTION_FRONTEND_MUTATION=NONE')
raise SystemExit(1 if failed else 0)
