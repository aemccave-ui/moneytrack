#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R3_REFERENCE_SETTINGS_GATE=FAIL check={name}")


editor = read('miniapp/src/TransactionEditor.jsx')
create_sheet = read('miniapp/src/AccountCreateSheet.jsx')
refs = read('miniapp/src/reference-options.js')
quick = read('miniapp/src/quick-actions-runtime.js')
quick_portal = read('miniapp/src/QuickOperationPortal.jsx')
settings = read('miniapp/src/SettingsPortal.jsx')
filters = read('miniapp/src/AccountsFilters.jsx')
runtime = read('miniapp/src/ux022r3-reference-runtime.js')
api = read('miniapp/src/api.js')
main = read('miniapp/src/main.jsx')
category_sql = read('db/domain/UX-022/070_category_flow_settings.sql')
category_workflow = read('scripts/ux022r3-generate-category-settings-workflow.py')
quick_workflow = read('scripts/ux022r3-generate-quick-input-workflow.py')
receipt_metadata_sql = read('db/domain/UX-022/080_receipt_operation_metadata.sql')
receipt_patch = read('scripts/ux022r3-patch-receipt-operation-metadata.py')

require(
    'used_currencies_before_catalog_tail',
    'orderedCurrencyCodes' in refs
    and "reference.filter((item) => item.usageCount > 0)" in refs
    and "filter((code) => !used.has(code)).sort(sort)" in refs
    and 'buildCurrencyOptions(reference.currencies, usedAccountCurrencies, form.currency)' in editor
    and 'buildCurrencyOptions(referenceCurrencies, usedCurrencies, currencyCode)' in create_sheet,
)
require(
    'operation_datetime_display_contract',
    "placeholder=\"ДД.ММ.ГГГГ\"" in editor
    and "placeholder=\"ЧЧ:ММ\"" in editor
    and "^([01]\\d|2[0-3]):[0-5]\\d$" in editor
    and "match(/^(\\d{2})\\.(\\d{2})\\.(\\d{4})$/)" in editor,
)
require(
    'new_operation_defaults_now',
    "const creating = mode === 'create'" in editor
    and 'isoParts(creating || repeat ? null : operation.transaction_date)' in editor
    and "mode=\"create\"" in quick_portal
    and "window.addEventListener('moneytrack:new-operation'" in quick_portal,
)
require(
    'fab_operation_and_receipt_photo_label',
    "button.innerHTML = '<span>Операция</span>" in quick
    and "labelNode.textContent = 'Фото чека'" in quick
    and "label === 'Операция'" in quick
    and "label === 'Фото чека' || label === 'Фото'" in quick
    and "labelNode?.textContent?.trim() === 'Голос'" not in quick,
)
require(
    'account_type_reference_shared',
    'ACCOUNT_TYPE_OPTIONS' in refs
    and 'accountTypeOptions(accountType)' in create_sheet
    and 'enhanceAccountTypeEditor' in runtime
    and "labelText !== 'Тип'" in runtime
    and 'accountTypeOptions(input.value)' in runtime,
)
require(
    'category_flow_metadata_source',
    'add column if not exists flow_type text' in category_sql
    and "check (flow_type in ('income','expense'))" in category_sql
    and 'category_update_v1' in category_sql
    and "'flow_type', cr.flow_type" in category_sql,
)
require(
    'category_filter_single_column_compat',
    'draftCategories' in filters
    and 'categoryMatrixHeader single' in filters
    and 'categoryMatrixRow single' in filters
    and 'draftIncome' not in filters
    and 'draftExpense' not in filters
    and "categoryFlow(item) === 'income'" in filters
    and 'incomeCategoryIds:' in filters
    and 'expenseCategoryIds:' in filters,
)
require(
    'category_settings_screen_and_api',
    'SettingsPortal' in main
    and 'updateCategory' in api
    and 'updateCategory({' in settings
    and '<option value="expense">Расход</option>' in settings
    and '<option value="income">Приход</option>' in settings
    and "'api/v1/categories'" in category_workflow
    and 'category_update_v1' in category_workflow,
)
require(
    'text_and_voice_use_current_ingress_time',
    quick_workflow.count('message_date: Math.floor(Date.now()/1000)') >= 3,
)
require(
    'receipt_uses_receipt_clock_when_available',
    'receipt_finalize_transaction_metadata_v1' in receipt_metadata_sql
    and "v_time_status := 'receipt_time'" in receipt_metadata_sql
    and "to_char(v_fallback_at, 'HH24:MI:SS')" in receipt_metadata_sql
    and 'receipt.receipt_time || receipt.time' in receipt_patch
    and 'receipt.receipt_datetime || receipt.receipt_date' in receipt_patch
    and 'receipt_finalize_transaction_metadata_v1' in receipt_patch,
)
require(
    'receipt_category_is_conservative',
    'count(distinct ri.category_id)' in receipt_metadata_sql
    and "v_category_status := 'single_item_category'" in receipt_metadata_sql
    and "v_category_status := 'mixed_categories'" in receipt_metadata_sql
    and 'set transaction_date = v_effective_at' in receipt_metadata_sql
    and 'category_id = v_category_id' in receipt_metadata_sql,
)

print('UX022R3_REFERENCE_SETTINGS_GATE=PASS')
