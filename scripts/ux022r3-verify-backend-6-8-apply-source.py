#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f'UX022R3_BACKEND_6_8_APPLY_SOURCE=FAIL check={name}')


seed = read('db/domain/UX-022/072_category_flow_canonical_seed.sql')
clock = read('scripts/ux022r3-patch-photo-receipt-clock.py')
metadata = read('scripts/ux022r3-patch-receipt-operation-metadata.py')
text = read('scripts/be-dom-001-transform-text-write.py')
quick = read('scripts/ux022r3-patch-quick-ingress-time.py')
category = read('db/domain/UX-022/070_category_flow_settings.sql')
bootstrap = read('db/domain/UX-022/071_category_flow_bootstrap_hardening.sql')
receipt_sql = read('db/domain/UX-022/080_receipt_operation_metadata.sql')
apply_gate = read('scripts/ux022r3-backend-6-8-apply-gate.sh')
apply_script = read('scripts/ux022r3-backend-6-8-apply.sh')

require(
    'photo_prompt_requests_explicit_receipt_time',
    'receipt_time,' in clock
    and '24h HH:MM or HH:MM:SS' in clock
    and 'Never invent receipt_time' in clock,
)
require(
    'photo_clock_patch_is_runtime_hash_pinned',
    'EXPECTED_PROMPT_SHA256' in clock
    and 'EXPECTED_PARSE_SHA256' in clock
    and 'Analyze image prompt drift' in clock
    and 'Parse receipt JSON drift' in clock,
)
require(
    'photo_parser_preserves_clock',
    'function normalizeTime(value)' in clock
    and 'receipt_time: normalizedTime' in clock
    and 'parsed.receipt_time' in clock,
)
require(
    'receipt_finalizer_consumes_parser_clock',
    'receipt.receipt_time || receipt.time' in metadata
    and 'receipt_finalize_transaction_metadata_v1' in metadata
    and "v_time_status := 'receipt_time'" in receipt_sql,
)
require(
    'text_voice_use_ingress_clock',
    'message_date' in quick
    and "to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date" in text,
)
require(
    'category_flow_is_two_state_for_user_categories',
    "check (flow_type in ('income','expense'))" in category
    and "v_flow not in ('income','expense')" in category,
)
require(
    'canonical_income_and_expense_seed',
    "set flow_type = 'income'" in seed
    and "c.code = 'income'" in seed
    and "set flow_type = 'expense'" in seed
    and "'food.groceries'" in seed
    and "'finance.fees'" in seed,
)
require(
    'legacy_semantic_families_seeded',
    "c.code like 'income.%'" in seed
    and "c.code like 'legal.%'" in seed
    and "c.code like 'life.%'" in seed
    and "c.code like 'other.%'" in seed
    and "c.code like 'required.%'" in seed,
)
require(
    'system_category_codes_are_not_fake_flows',
    "c.code in ('transfer', 'uncategorized')" in seed
    and 'set is_active = false' in seed
    and 'flow_type = null' in seed,
)
require(
    'category_seed_fails_closed_on_remaining_active_unknowns',
    'UX022R3_CATEGORY_FLOW_UNRESOLVED_AFTER_CANONICAL_SEED' in seed
    and 'UX022R3_TEMPLATE_FLOW_UNRESOLVED_AFTER_CANONICAL_SEED' in seed,
)
require(
    'future_bootstrap_copies_flow',
    'flow_type' in bootstrap
    and bootstrap.count('tc.flow_type') >= 2,
)
require(
    'backend_shell_locals_are_nounset_safe',
    'local id="$1"\n  local target="$2"\n  local remote=' in apply_gate
    and 'local id="$1"\n  local target="$2"\n  local remote=' in apply_script
    and 'local file="$1"\n  local id="$2"\n  local remote=' in apply_script
    and 'local id="$1" target="$2" remote=' not in apply_gate
    and 'local id="$1" target="$2" remote=' not in apply_script
    and 'local file="$1" id="$2" remote=' not in apply_script,
)
require(
    'new_category_webhook_has_functional_rollback',
    'CATEGORY_MUTATED=0' in apply_script
    and 'write_inert_category "$BACKUP_DIR/category.rollback-inert.json"' in apply_script
    and 'n8n-nodes-base.manualTrigger' in apply_script
    and 'import_publish "$BACKUP_DIR/category.rollback-inert.json" "$CATEGORY_ID"' in apply_script
    and 'rollback_category_workflow=PASS published_inert_replacement' in apply_script
    and 'rollback_category_webhook_absent=PASS http=404' in apply_script
    and 'verify_category_webhook_absent' in apply_script,
)

print('UX022R3_BACKEND_6_8_APPLY_SOURCE=PASS')
