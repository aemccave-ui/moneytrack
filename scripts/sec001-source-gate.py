#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def req(name: str, condition: bool, detail: str = '') -> None:
    if not condition:
        raise SystemExit(f'{name}=FAIL' + (f' detail={detail}' if detail else ''))
    print(f'{name}=PASS')


def load_module(rel: str, name: str):
    path = ROOT / rel
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SystemExit(f'cannot load {rel}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def nodes(wf: dict) -> dict[str, dict]:
    return {n['name']: n for n in wf.get('nodes', []) if n.get('name')}


def lanes(wf: dict, source: str) -> list[list[dict]]:
    return ((wf.get('connections') or {}).get(source) or {}).get('main') or []


def direct(wf: dict, source: str, branch: int = 0) -> list[str]:
    xs = lanes(wf, source)
    if branch >= len(xs):
        return []
    return [e.get('node') for e in xs[branch] if e.get('node')]


def one(wf: dict, source: str, branch: int = 0) -> str:
    out = direct(wf, source, branch)
    if len(out) != 1:
        raise SystemExit(f'graph expected one target from {source}[{branch}], got {out}')
    return out[0]


def webhook_by_path(wf: dict, path: str) -> dict:
    found = [n for n in wf.get('nodes', []) if n.get('type') == 'n8n-nodes-base.webhook' and str((n.get('parameters') or {}).get('path') or '').lstrip('/') == path]
    if len(found) != 1:
        raise SystemExit(f'webhook owner mismatch for {path}: {[n.get("name") for n in found]}')
    return found[0]


def reachable(wf: dict, starts: list[str]) -> set[str]:
    todo = deque(starts)
    seen: set[str] = set()
    while todo:
        name = todo.popleft()
        if name in seen:
            continue
        seen.add(name)
        for lane in lanes(wf, name):
            for edge in lane:
                if edge.get('node') and edge['node'] not in seen:
                    todo.append(edge['node'])
    return seen


def node_text(node: dict) -> str:
    return json.dumps(node, ensure_ascii=False, sort_keys=True)


def assert_unlock_chain(wf: dict, path: str, expected_after_unlock: str | None = None) -> None:
    wh = webhook_by_path(wf, path)
    verify = one(wf, wh['name'])
    verify_node = nodes(wf)[verify]
    req(f'{path}:telegram_verifier_type', verify_node.get('type') == 'n8n-nodes-base.code')
    verify_js = str((verify_node.get('parameters') or {}).get('jsCode') or '')
    req(f'{path}:telegram_verifier_canonical', 'moneytrackVerifyTelegramInitData' in verify_js)
    auth = one(wf, verify)
    req(f'{path}:telegram_gate_type', nodes(wf)[auth].get('type') == 'n8n-nodes-base.if')
    prepare = one(wf, auth, 0)
    req(f'{path}:unlock_prepare', prepare == f'SEC001 Unlock Prepare [{path}]')
    req(f'{path}:unlock_prepare_type', nodes(wf)[prepare].get('type') == 'n8n-nodes-base.code')
    verify_unlock = one(wf, prepare)
    req(f'{path}:unlock_db_type', nodes(wf)[verify_unlock].get('type') == 'n8n-nodes-base.postgres')
    query = str((nodes(wf)[verify_unlock].get('parameters') or {}).get('query') or '')
    req(f'{path}:unlock_db_contract', 'security_validate_unlock_v1' in query)
    decision = one(wf, verify_unlock)
    gate = one(wf, decision)
    req(f'{path}:unlock_gate_type', nodes(wf)[gate].get('type') == 'n8n-nodes-base.if')
    reject = one(wf, gate, 1)
    req(f'{path}:unlock_reject_type', nodes(wf)[reject].get('type') == 'n8n-nodes-base.respondToWebhook')
    if expected_after_unlock:
        req(f'{path}:domain_after_unlock', expected_after_unlock in direct(wf, gate, 0), str(direct(wf, gate, 0)))


def function_body(sql: str, function_name: str) -> str:
    start = sql.find(f'create or replace function moneytrack.{function_name}(')
    if start < 0:
        raise SystemExit(f'missing function {function_name}')
    end = sql.find('$function$;', start)
    if end < 0:
        raise SystemExit(f'unterminated function {function_name}')
    return sql[start:end]


gen = load_module('scripts/sec001-generate-security-api.py', 'sec001_gen')
transformer = load_module('scripts/sec001-transform-class-b.py', 'sec001_transform')
security_raw = gen.build('test-postgres', 'Postgres account')
security_candidate, protected_security = transformer.transform(security_raw, 'test-postgres', 'Postgres account')
raw_nodes = nodes(security_raw)

enroll_format_js = str(
    (raw_nodes['Biometric Enroll Format'].get('parameters') or {}).get('jsCode') or ''
)
req(
    'biometric_enroll_returns_prepared_token',
    '$("Biometric Enroll Prepare")' in enroll_format_js
    and '$("Biometric Enroll Verify")' not in enroll_format_js
    and 'biometric_token:prepared.biometric_token' in enroll_format_js,
)

# ------------------------------------------------------------------
# New-user Class A bootstrap: inspect actual generated graph.
# ------------------------------------------------------------------
status_wh = webhook_by_path(security_raw, 'api/v1/security/status')
req('new_user_bootstrap_before_security_status', one(security_raw, 'Security Status Telegram OK', 0) == 'Security Status User Bootstrap' and one(security_raw, 'Security Status User Bootstrap') == 'Security Status Backend')
bootstrap_node = raw_nodes['Security Status User Bootstrap']
status_node = raw_nodes['Security Status Backend']
bootstrap_query = str((bootstrap_node.get('parameters') or {}).get('query') or '')
status_query = str((status_node.get('parameters') or {}).get('query') or '')
req('canonical_user_bootstrap_reused', bootstrap_node.get('type') == 'n8n-nodes-base.postgres' and 'moneytrack.user_bootstrap_v1' in bootstrap_query)
req('new_user_not_deadlocked', 'security_status_v1' in status_query and one(security_raw, 'Security Status Backend') == 'Security Status Format')
status_format = str((raw_nodes['Security Status Format'].get('parameters') or {}).get('jsCode') or '')
for forbidden in ('base_currency', 'report_currency', 'workspace_id', 'default_expense_account_id', 'default_income_account_id'):
    req(f'class_a_status_no_{forbidden}', forbidden not in status_format)

lifecycle = (ROOT / 'db/domain/BE-DOM-003/010_user_lifecycle_domain.sql').read_text(encoding='utf-8')
security_sql = (ROOT / 'db/domain/SEC-001/010_application_lock.sql').read_text(encoding='utf-8')
req('canonical_user_bootstrap_exists', 'create or replace function moneytrack.user_bootstrap_v1(' in lifecycle)
req('canonical_user_bootstrap_not_duplicated', 'create or replace function moneytrack.user_bootstrap_v1(' not in security_sql)
req('NEW_USER_SECURITY_BOOTSTRAP', 'moneytrack.user_bootstrap_v1' in bootstrap_query)
req('NEW_USER_APP_USER_CREATED', 'insert into moneytrack.app_users' in lifecycle and 'moneytrack.user_bootstrap_v1' in bootstrap_query)
req('NEW_USER_PROTECTION_DEFAULT_OFF', 'pin_enabled boolean not null default false' in security_sql and 'coalesce(s.pin_enabled, false)' in security_sql)
gate_src = (ROOT / 'miniapp/src/SecurityGate.jsx').read_text(encoding='utf-8')
req('NEW_USER_CAN_ENTER_APP', "if (enabled)" in gate_src and "setMode('open')" in gate_src)

# ------------------------------------------------------------------
# Class B lifecycle routes: inspect transformed candidate graph.
# ------------------------------------------------------------------
for path, after in (
    ('api/v1/security/pin/change', 'PIN Change State'),
    ('api/v1/security/disable', 'Security Disable State'),
    ('api/v1/security/biometric/enroll', 'Biometric Enroll Prepare'),
    ('api/v1/security/biometric/revoke', 'Biometric Revoke Prepare'),
):
    req(f'{path}:protected_list', path in protected_security)
    req(f'{path}:not_class_a', path not in transformer.CLASS_A_PATHS)
    assert_unlock_chain(security_candidate, path, after)

pin_change = function_body(security_sql, 'security_change_pin_v1')
disable = function_body(security_sql, 'security_disable_v1')
pin_change_js = str((raw_nodes['PIN Change Check'].get('parameters') or {}).get('jsCode') or '')
disable_js = str((raw_nodes['Security Disable Check'].get('parameters') or {}).get('jsCode') or '')

req('pin_change_class_b', 'api/v1/security/pin/change' in protected_security)
req('pin_change_current_pin_required', 'current_pin' in pin_change_js and 'scryptSync' in pin_change_js and 'timingSafeEqual' in pin_change_js)
req('pin_change_rotates_security_version', 'security_version = s.security_version + 1' in pin_change)
req('pin_change_revokes_old_sessions', 'update moneytrack.user_unlock_sessions' in pin_change and 'where us.user_id = p_user_id' in pin_change and 'insert into moneytrack.user_unlock_sessions' in pin_change)
req('disable_security_class_b', 'api/v1/security/disable' in protected_security)
req('disable_requires_pin', 'current_pin' in disable_js and 'body.confirm !== true' in disable_js and 'timingSafeEqual' in disable_js)
req('disable_revokes_all_sessions', 'update moneytrack.user_unlock_sessions' in disable and 'where us.user_id = p_user_id' in disable)
req('disable_revokes_all_biometrics', 'update moneytrack.user_biometric_credentials' in disable and 'where b.user_id = p_user_id' in disable and 'device_id' not in disable)
req('disable_clears_verifier', 'pin_enabled = false' in disable and 'pin_salt = null' in disable and 'pin_verifier = null' in disable)

# ------------------------------------------------------------------
# Actual MiniApp quick-input candidate: text/photo/voice must be Class B.
# ------------------------------------------------------------------
quick_gen = load_module('scripts/ux022r3-generate-quick-input-workflow.py', 'quick_gen')
quick_raw = quick_gen.build('test-postgres', 'Postgres account')
quick_candidate, quick_protected = transformer.transform(quick_raw, 'test-postgres', 'Postgres account')
for path, after in (
    ('api/v1/transaction/text', 'Text User Context'),
    ('api/v1/transaction/photo', 'Photo User Context'),
    ('api/v1/transaction/voice', 'Voice User Context'),
):
    req(f'miniapp_{path.rsplit("/",1)[-1]}_class_b', path in quick_protected)
    assert_unlock_chain(quick_candidate, path, after)
req('miniapp_quick_input_is_class_b', all(p in quick_protected for p in ('api/v1/transaction/text','api/v1/transaction/photo','api/v1/transaction/voice')))

# ------------------------------------------------------------------
# Actual Telegram Bot workflow: transformer must leave the TelegramTrigger
# reachable graph free of SEC001 unlock nodes, and quick-capture node types
# for photo/voice/text must remain reachable.
# ------------------------------------------------------------------
bot_raw = json.loads((ROOT / 'workflows/moneytrack-DER2Lc3dT2afyQhy.json').read_text(encoding='utf-8'))
trigger_names = [n['name'] for n in bot_raw.get('nodes', []) if n.get('type') == 'n8n-nodes-base.telegramTrigger']
req('bot_has_real_telegram_trigger', bool(trigger_names))
before_reachable = reachable(bot_raw, trigger_names)
bot_candidate, _ = transformer.transform(bot_raw, 'test-postgres', 'Postgres account')
after_reachable = reachable(bot_candidate, trigger_names)
req('class_c_trigger_graph_names_unchanged', before_reachable == after_reachable)
before_bot_nodes = nodes(bot_raw)
bot_nodes = nodes(bot_candidate)
req('class_c_trigger_node_types_unchanged', all(
    name in before_bot_nodes and name in bot_nodes and before_bot_nodes[name].get('type') == bot_nodes[name].get('type')
    for name in before_reachable
))
req('class_c_trigger_connections_unchanged', all(
    lanes(bot_raw, name) == lanes(bot_candidate, name) for name in before_reachable
))
req('class_c_trigger_graph_no_unlock_nodes', not any(name.startswith('SEC001 Unlock') for name in after_reachable))
serialized_reachable = '\n'.join(node_text(bot_nodes[name]).lower() for name in sorted(after_reachable) if name in bot_nodes)
req('bot_quick_capture_photo_reachable', 'photo' in serialized_reachable)
req('bot_quick_capture_voice_reachable', 'voice' in serialized_reachable)
req('bot_quick_capture_text_reachable', 'message_text' in serialized_reachable or 'message.text' in serialized_reachable or 'message text' in serialized_reachable)
req('class_c_bot_capture_does_not_require_unlock', not any('security_validate_unlock_v1' in node_text(bot_nodes[name]) for name in after_reachable if name in bot_nodes))
req('bot_quick_capture_is_class_c', all(x in serialized_reachable for x in ('photo','voice')) and bool(trigger_names))

# SEC-001 Class C is quick capture only. Legacy slash-command/report
# branches may remain physically present for forensic/rollback purposes,
# but they must be unreachable from TelegramTrigger.
command_gate = before_bot_nodes.get('Is command')
req(
    'bot_command_classifier_present',
    command_gate is not None
)
req(
    'legacy_bot_command_branch_closed',
    direct(bot_raw, 'Is command', 0) == [],
    str(direct(bot_raw, 'Is command', 0)),
)
req(
    'bot_non_command_text_capture_preserved',
    bool(direct(bot_raw, 'Is command', 1)),
    str(direct(bot_raw, 'Is command', 1)),
)
req(
    'legacy_bot_command_router_unreachable',
    'Switch commands' not in before_reachable
)
req(
    'legacy_private_bot_commands_unreachable',
    all(
        marker not in serialized_reachable
        for marker in ('/summary', '/last', '/settings')
    )
)

# ------------------------------------------------------------------
# Frozen cross-cutting source invariants.
# ------------------------------------------------------------------
api = (ROOT / 'miniapp/src/api.js').read_text(encoding='utf-8')
main = (ROOT / 'miniapp/src/main.jsx').read_text(encoding='utf-8')
settings = (ROOT / 'miniapp/src/SecuritySettings.jsx').read_text(encoding='utf-8')
session = (ROOT / 'miniapp/src/security-session.js').read_text(encoding='utf-8')
transform_src = (ROOT / 'scripts/sec001-transform-class-b.py').read_text(encoding='utf-8')
unlock_fragment = (ROOT / 'scripts/sec001-unlock-verifier.fragment.js').read_text(encoding='utf-8')

req('telegram_auth_preserved', 'moneytrackVerifyTelegramInitData' in json.dumps(security_raw) and 'moneytrackVerifyTelegramInitData' in json.dumps(quick_raw))
req('class_a_minimal', transformer.CLASS_A_PATHS == {'api/v1/security/status','api/v1/security/pin/setup','api/v1/security/pin/unlock','api/v1/security/biometric/unlock'})
req('class_b_requires_unlock', 'security_validate_unlock_v1' in json.dumps(security_candidate))
protected_start = main.find('function ProtectedApplication()')
root_start = main.find('createRoot(')

protected_mount_ok = (
    protected_start >= 0
    and root_start > protected_start
)

protected_body = (
    main[protected_start:root_start]
    if protected_mount_ok
    else ''
)

root_body = (
    main[root_start:]
    if root_start >= 0
    else ''
)

security_gate_before_app = (
    '<SecurityGate>' in root_body
    and '<ProtectedApplication />' in root_body
    and '</SecurityGate>' in root_body
    and root_body.index('<SecurityGate>')
        < root_body.index('<ProtectedApplication />')
        < root_body.index('</SecurityGate>')
)

private_children_isolated = (
    '<App />' in protected_body
    and '<QuickOperationPortal />' in protected_body
    and '<SettingsPortal />' in protected_body
    and '<App />' not in root_body
    and '<QuickOperationPortal />' not in root_body
    and '<SettingsPortal />' not in root_body
)

security_gate_fail_closed = (
    "if (mode === 'open') return children" in gate_src
    and "if (mode === 'loading')" in gate_src
    and "if (mode === 'error')" in gate_src
)

req('security_gate_before_app', security_gate_before_app)
req(
    'no_private_fetch_before_unlock',
    protected_mount_ok
    and private_children_isolated
    and security_gate_before_app
    and security_gate_fail_closed
)
pin_regex = r'/^\d{6}$/'

pin_validation_nodes = {
    name: str(
        (raw_nodes[name].get('parameters') or {}).get('jsCode') or ''
    )
    for name in (
        'PIN Setup Verify',
        'PIN Check',
        'PIN Change Check',
        'Security Disable Check',
    )
}

pin_regex_missing = [
    name
    for name, js in pin_validation_nodes.items()
    if pin_regex not in js
]

req(
    'six_digit_pin',
    not pin_regex_missing,
    ','.join(pin_regex_missing),
)
req('pin_server_side', 'MONEYTRACK_PIN_PEPPER' in json.dumps(security_raw) and 'scryptSync' in json.dumps(security_raw))
req('pin_not_plaintext', 'pin_verifier' in security_sql and ' plaintext ' not in security_sql.lower())
req('pin_rate_limit', 'v_attempts >= 5' in security_sql and "interval '5 minutes'" in security_sql)
req('unlock_token_user_bound', 's.user_id = v_user_id' in security_sql and 's.security_version = v_version' in security_sql)
req('unlock_token_short_lived', '900' in json.dumps(security_raw) and 'p_ttl_seconds integer default 900' in security_sql)
req('unlock_token_memory_only', all(x not in session for x in ('localStorage','sessionStorage','CloudStorage')) and 'let unlockToken' in session)
req('unlock_header_centralized', "X-MoneyTrack-Unlock-Token" in api and 'getUnlockToken' in api)
req('biometric_manager_used', 'BiometricManager' in gate_src and 'BiometricManager' in settings)
req('biometric_device_binding', 'deviceId' in gate_src and 'deviceId' in settings and 'device_id' in security_sql)
req('raw_biometric_token_not_db', 'biometric_token_hash' in json.dumps(security_raw) and 'token_hash' in security_sql)
req('pin_fallback', 'Введите 6-значный PIN' in gate_src and 'Использовать биометрию' in gate_src)
req('background_relock', 'BACKGROUND_RELOCK_MS = 60_000' in gate_src and 'visibilitychange' in gate_src)
req('pin_change_frontend_fields', all(x in settings for x in ('Текущий PIN','Повторите новый PIN','changeSecurityPin')))
req('disable_frontend_confirm', 'disableSecurity' in settings and 'disableConfirmed' in settings and "updateBiometricToken(manager, '')" in settings and 'clearUnlockSession()' in settings)
req('legacy_private_bot_commands_not_part_of_new_auth', not any(p.startswith('api/v1/bot/') for p in protected_security))
req('production_not_targeted', security_raw.get('active') is False and security_raw.get('settings',{}).get('saveDataSuccessExecution') == 'none')
req('security_execution_persistence_disabled', security_raw.get('settings',{}).get('saveDataErrorExecution') == 'none' and security_raw.get('settings',{}).get('saveDataSuccessExecution') == 'none')
req('ux023_receipt_common_client_preserved', 'updateReceiptAccounting' in api and 'receipt-accounting-api.js' not in api)
req('obsolete_receipt_currency_not_reactivated', 'updateReceiptCurrency' not in api and 'api/v1/receipt/currency' not in api)
req('unlock_fragment_hash_only', 'createHash("sha256")' in unlock_fragment and 'unlock_token_hash' in unlock_fragment)
req('transform_unknown_api_fail_closed', 'if not path.startswith("api/v1/")' in transform_src and 'if path in CLASS_A_PATHS' in transform_src)

print('SEC001_SOURCE_GATE=PASS')
