#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def text(path):
    return (ROOT / path).read_text(encoding='utf-8')


def require(name, condition, detail):
    status = 'PASS' if condition else 'FAIL'
    print(f'{name}={status} {detail}')
    if not condition:
        FAILURES.append(name)


FAILURES = []
app = text('miniapp/src/App.jsx')
recent = text('miniapp/src/RecentOperations.jsx')
editor = text('miniapp/src/TransactionEditor.jsx')
receipt = text('miniapp/src/ReceiptModal.jsx')
source = text('miniapp/src/operation-source.jsx')
periods = text('miniapp/src/date-format.js')
explorer = text('miniapp/src/AccountsExplorer.jsx')
explorer_css = text('miniapp/src/accounts-explorer.css')
source_sql = text('db/domain/UX-024/010_operation_source_and_datetime_guard.sql')
read_sql = text('db/domain/UX-024/020_operation_source_read_models.sql')
text_ingress = text('scripts/be-dom-001-transform-text-write.py')
receipt_accounting = text('miniapp/src/receipt-accounting-api.js')

require('operation_modal_for_all_operations', "setEditor({ operation: tx, mode: 'edit', kind: 'transaction' })" in recent, 'ordinary tap routes to TransactionEditor')
require('receipt_modal_preserved', '<ReceiptModal' in recent and 'getReceiptByTransaction' in recent, 'receipt relation still opens ReceiptModal')
require('operation_inline_expansion_not_primary_tap_path', 'expandedId' not in recent and 'transactionDetails' not in recent, 'ordinary inline expansion removed')
require('swipe_edit_removed', "label: 'Изменить'" not in recent, 'no Edit swipe action')
require('swipe_copy_repeat_removed', "label: 'Повторить'" not in recent and 'RepeatIcon' not in recent, 'no Copy/Repeat swipe action')
require('source_icon_present', 'OperationSourceIcon' in editor and 'OperationSourceIcon' in receipt, 'both operation modal families show source')
require('source_icon_not_heuristic', 'description' not in source and 'category' not in source and 'transaction_date' not in source, 'source helper reads persisted source_kind/source_type only')
require('manual_datetime_editable', 'transactionEditorPickerField' in editor and "kind={creating ? 'manual'" in editor, 'manual editor has date/time pickers')
require('text_datetime_editable', 'transactionEditorPickerField' in editor and "text: 'text'" in source, 'text uses ordinary editor')
require('voice_datetime_editable', 'transactionEditorPickerField' in editor and "voice: 'voice'" in source, 'voice uses ordinary editor')
require('receipt_datetime_immutable_ui', 'receiptDateTime(' in receipt and 'type="date"' not in receipt and 'type="time"' not in receipt, 'receipt datetime rendered read-only')
require('receipt_datetime_immutable_backend', 'RECEIPT_DATETIME_IMMUTABLE' in source_sql and "operation_source_kind_v1(p_user_id, p_transaction_id) = 'photo_receipt'" in source_sql, 'generic update rejects receipt datetime mutation')
require('receipt_category_change_keeps_modal_open', 'receiptRefreshPending' in recent and 'setReceiptView(null)' in recent and 'receiptChanged' in recent, 'parent refresh deferred until explicit close')
require('currency_chip_visual_contract', '.currencyGroupHeader' in explorer_css and '.accountTreeRow' in explorer_css, 'currency/account visual language shares shell semantics')
require('currency_count_badge', 'homeCountBadge' in app and 'group.accounts.length' in app, 'currency badge uses operational account count')
require('account_count_badge', 'leafCount' in app and 'homeCountBadge' in app, 'account badge uses descendant leaf count')
require('calendar_week_monday_sunday', 'mondayOffset = (anchor.getDay() + 6) % 7' in periods and 'addLocalDays(monday, 6)' in periods, 'week resolves local Monday through Sunday')
require('week_not_rolling_seven_days', 'today - 6' not in periods and "period === 'week') from.setDate" not in explorer, 'rolling week implementation absent')
require('year_period_present', "period === 'year'" in explorer and '>Год</button>' in explorer and "homePeriod === 'year'" in app and "dateFrom: `${year}-01-01`" in periods, 'year is canonical on Home and Accounts')
require('previous_next_week', 'shiftPeriod(period, current, direction)' in explorer and 'shiftPeriod(homePeriod, current, -1)' in app and "periodType === 'week'" in periods, 'week shifts anchor by calendar week')
require('previous_next_month', 'shiftPeriod(period, current, direction)' in explorer and 'shiftPeriod(homePeriod, current, 1)' in app and "periodType === 'month'" in periods, 'month shifts anchor by calendar month')
require('previous_next_year', 'shiftPeriod(period, current, direction)' in explorer and 'shiftPeriod(homePeriod, current, 1)' in app and "periodType === 'year'" in periods, 'year shifts anchor by calendar year')
require('single_period_model', 'resolvePeriod(period, anchorDate' in explorer and 'resolvePeriod(homePeriod, homeAnchorDate)' in app and 'export function resolvePeriod' in periods and 'export function shiftPeriod' in periods, 'Home and Accounts share one period abstraction')
require('home_period_summary_separate_from_balance_snapshot', 'homePeriodState' in app and 'homeSnapshotState' in app and 'resolvedHomePeriod.displayLabel' in app, 'historical turnover navigation does not replace current balance snapshot')
require('existing_receipt_accounting_contract_preserved', 'updateReceiptAccounting' in receipt and 'updateReceiptAccounting' in receipt_accounting, 'UX-023 atomic receipt accounting path retained')
require('persisted_source_read_model', "'source_kind', x.source_kind" in read_sql and "'source_kind', t.source_kind" in read_sql, 'dashboard and account operation JSON expose persisted source')
require('text_voice_source_ingress', 'finance_create_sourced_transaction_v1' in text_ingress and 'SOURCE_EXPR' in text_ingress and 'source_content_heuristics=NONE' in text_ingress, 'text/voice source comes from ingress contract')
require('production_frontend_not_targeted', 'production' not in recent.lower() and 'production' not in explorer.lower() and 'production' not in app.lower(), 'UX-024 frontend source contains no deployment target mutation')

if FAILURES:
    print('UX024_SOURCE_GATE=FAIL')
    print('failed=' + ','.join(FAILURES))
    sys.exit(1)
print('UX024_SOURCE_GATE=PASS')
