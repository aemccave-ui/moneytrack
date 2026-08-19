#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool, detail: str) -> None:
    status = 'PASS' if condition else 'FAIL'
    print(f'{name}={status} {detail}')
    if not condition:
        FAILURES.append(name)


FAILURES: list[str] = []
repair = text('db/domain/SPC-001/219_home_operation_open_contract_repair.sql')
recent = text('miniapp/src/RecentOperations.jsx')
source = text('miniapp/src/operation-source.jsx')
dispatch = text('db/domain/SPC-001/040_space_api_dispatch.sql')

receipt_marker = 'create or replace function moneytrack.receipt_projection_api_read_v1('
receipt_block = repair.split(receipt_marker, 1)[1] if receipt_marker in repair else ''

require(
    'home_dashboard_source_kind_restored',
    'as source_kind' in repair
    and 'left join moneytrack.capture_events ce on ce.id=t.capture_event_id' in repair
    and 't.source_type,t.capture_event_id' in repair,
    'Space dashboard latest_operations carries canonical source metadata',
)
require(
    'home_dashboard_source_mapping_complete',
    all(token in repair for token in [
        "when 'miniapp' then 'manual'",
        "when 'manual' then 'manual'",
        "when 'text' then 'text'",
        "when 'voice' then 'voice'",
        "when 'photo' then 'photo_receipt'",
        "when 'photo_receipt' then 'photo_receipt'",
    ]),
    'manual/text/voice/photo source kinds are preserved',
)
require(
    'receipt_lookup_existing_non_receipt_returns_null',
    bool(receipt_block)
    and "raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE'" in receipt_block
    and 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' not in receipt_block
    and 'return v_result;' in receipt_block,
    'existing Space transaction without capture_receipt is a valid NULL receipt result',
)
require(
    'receipt_lookup_cross_space_fails_closed',
    'where t.id=p_transaction_id' in receipt_block
    and 'and t.space_id=p_space_id' in receipt_block
    and "raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE'" in receipt_block,
    'receipt lookup never treats an out-of-Space transaction as an ordinary missing receipt',
)
require(
    'dispatcher_serializes_nullable_receipt',
    "v_result:=jsonb_build_object('receipt',moneytrack.receipt_projection_api_read_v1" in dispatch,
    'GET /api/v1/receipt preserves receipt:null from the domain boundary',
)
require(
    'frontend_manual_text_voice_open_transaction_editor',
    "setEditor({ operation: tx, mode: 'edit', kind: 'transaction' })" in recent
    and "SOURCE_KIND_BY_TYPE" in source
    and "text: 'text'" in source
    and "voice: 'voice'" in source
    and "manual: 'manual'" in source,
    'non-receipt persisted source kinds route to TransactionEditor',
)
require(
    'frontend_photo_receipt_opens_receipt_modal',
    "sourceKind === 'photo_receipt'" in recent
    and 'setReceiptView({ transaction: tx, receipt: lookup.receipt })' in recent,
    'photo receipt route remains ReceiptModal',
)
require(
    'frontend_legacy_unknown_source_fallback_safe',
    'sourceKind == null' in recent
    and 'if (lookup.receipt)' in recent
    and "setEditor({ operation: tx, mode: 'edit', kind: 'transaction' })" in recent,
    'legacy unknown source may probe receipt and then fall back to TransactionEditor',
)

if FAILURES:
    print('SPC001_HOME_OPERATION_CONTRACT_GATE=FAIL')
    print('failed=' + ','.join(FAILURES))
    sys.exit(1)

print('SPC001_HOME_OPERATION_CONTRACT_GATE=PASS')
