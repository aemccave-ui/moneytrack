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
reference_runtime_css = text('miniapp/src/ux022r3-reference-runtime.css')
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
require('currency_count_badge', 'currencyRowCountBadge' in app and 'group.accounts.length' in app, 'currency row starts with operational account count badge')
require('account_count_badge', 'accountRowCountBadge' in app and 'node.leafCount' in app, 'account row starts with descendant leaf count badge')
require('currency_count_badge_leading', app.index('currencyRowCountBadge') < app.index('currencyBadge">{group.currency}'), 'currency count badge precedes currency label')
require('account_count_badge_leading', app.index('accountRowCountBadge') < app.index('accountTreeIdentity'), 'account count badge precedes account identity')
require('breakdown_badges_visible_after_legacy_css', '.homeCountBadge.currencyRowCountBadge,.accountDistribution .accountTree .homeCountBadge.accountRowCountBadge{display:inline-flex!important}' in reference_runtime_css, 'late UX022R3 runtime CSS explicitly exposes UX024 breakdown badges')
require('calendar_week_monday_sunday', 'mondayOffset = (anchor.getDay() + 6) % 7' in periods and 'addLocalDays(monday, 6)' in periods, 'week resolves local Monday through Sunday')
require('week_not_rolling_seven_days', 'today - 6' not in periods and "period === 'week') from.setDate" not in explorer, 'rolling week implementation absent')
require('accounts_year_period_present', "period === 'year'" in explorer and '>Год</button>' in explorer and "dateFrom: `${year}-01-01`" in periods, 'year remains canonical on Accounts')
require('accounts_previous_next_week', 'shiftPeriod(period, current, direction)' in explorer and "periodType === 'week'" in periods, 'Accounts shifts by calendar week')
require('accounts_previous_next_month', 'shiftPeriod(period, current, direction)' in explorer and "periodType === 'month'" in periods, 'Accounts shifts by calendar month')
require('accounts_previous_next_year', 'shiftPeriod(period, current, direction)' in explorer and "periodType === 'year'" in periods, 'Accounts shifts by calendar year')
require('accounts_period_model', 'resolvePeriod(period, anchorDate' in explorer and 'export function resolvePeriod' in periods and 'export function shiftPeriod' in periods, 'period model remains on Accounts')
require('home_period_controls_removed', 'homePeriodTabs' not in app and 'homePeriodNavigation' not in app and 'setHomePeriod(' not in app and 'setHomeAnchorDate(' not in app, 'Home has no date filters')
require('home_current_month_summary', 'summary.result_month' in app and 'summary.income_month' in app and 'summary.expenses_month' in app and 'monthLabel(' in app, 'Home hero is fixed to current dashboard month')
require('home_balance_uses_current_snapshot', 'currentNetWorth' in app and 'canonicalLeafTotal' in app and 'currentNetWorthCurrency' in app, 'overall balance shares account snapshot')
require('home_legacy_networth_mismatch_removed', 'homeTotalsMismatch' not in app and 'Остатки не согласованы с общим балансом' not in app, 'legacy mismatch warning removed')
require('home_currency_distribution_present', 'Баланс по валютам' in app and 'currencyStackBar' in app and 'currencyGroups' in app, 'currency distribution is present')
require('existing_receipt_accounting_contract_preserved', 'updateReceiptAccounting' in receipt and 'updateReceiptAccounting' in receipt_accounting, 'UX-023 atomic receipt accounting path retained')
require('persisted_source_read_model', "'source_kind', x.source_kind" in read_sql and "'source_kind', t.source_kind" in read_sql, 'dashboard and account operation JSON expose persisted source')
require('text_voice_source_ingress', 'finance_create_sourced_transaction_v1' in text_ingress and 'SOURCE_EXPR' in text_ingress and 'source_content_heuristics=NONE' in text_ingress, 'text/voice source comes from ingress contract')
require('production_frontend_not_targeted', 'production' not in recent.lower() and 'production' not in explorer.lower() and 'production' not in app.lower(), 'UX-024 frontend source contains no deployment target mutation')

if FAILURES:
    print('UX024_SOURCE_GATE=FAIL')
    print('failed=' + ','.join(FAILURES))
    sys.exit(1)
print('UX024_SOURCE_GATE=PASS')
