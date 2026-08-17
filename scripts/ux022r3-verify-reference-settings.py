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
settings = read('miniapp/src/screens/SettingsScreen.jsx')
app = read('miniapp/src/App.jsx')
filters = read('miniapp/src/AccountsFilters.jsx')
runtime = read('miniapp/src/ux022r3-reference-runtime.js')
api = read('miniapp/src/api.js')
main = read('miniapp/src/main.jsx')
picker_css = read('miniapp/src/transaction-picker.css')
category_sql = read('db/domain/UX-022/070_category_flow_settings.sql')
category_bootstrap_sql = read('db/domain/UX-022/071_category_flow_bootstrap_hardening.sql')
category_workflow = read('scripts/ux022r3-generate-category-settings-workflow.py')
quick_workflow = read('scripts/ux022r3-generate-quick-input-workflow.py')
quick_time_patch = read('scripts/ux022r3-patch-quick-ingress-time.py')
text_write = read('scripts/be-dom-001-transform-text-write.py')
receipt_metadata_sql = read('db/domain/UX-022/080_receipt_operation_metadata.sql')
receipt_patch = read('scripts/ux022r3-patch-receipt-operation-metadata.py')
backend_forensic = read('scripts/ux022r3-backend-6-8-forensic.sh')

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
    'operation_datetime_native_pickers',
    'useRef' in editor
    and 'function showNativePicker(ref)' in editor
    and "typeof input.showPicker === 'function'" in editor
    and 'aria-label="Выбрать дату"' in editor
    and 'aria-label="Выбрать время"' in editor
    and 'className="transactionEditorNativePicker" type="date"' in editor
    and 'className="transactionEditorNativePicker" type="time"' in editor
    and "import './transaction-picker.css'" in main
    and '.transactionEditorPickerButton {' in picker_css
    and '.transactionEditorPickerControl > .transactionEditorNativePicker {' in picker_css,
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
    'ambiguous_category_flow_is_not_guessed',
    "set flow_type = 'expense'" not in category_sql.lower()
    and 'alter column flow_type set not null' not in category_sql.lower()
    and "nullif(lower(to_jsonb(c)->>'flow_type'), '') as flow_type" in category_sql
    and 'Mixed or never-used categories deliberately stay NULL' in category_sql
    and 'Mixed or unused codes remain NULL' in category_bootstrap_sql,
)
require(
    'category_flow_survives_new_user_bootstrap',
    'catalog_ensure_user_categories_v1' in category_bootstrap_sql
    and 'show_in_budget_report, budget_sort_order, flow_type' in category_bootstrap_sql
    and category_bootstrap_sql.count('tc.flow_type') >= 2
    and 'template.user_id = 0' in category_bootstrap_sql,
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
    and 'expenseCategoryIds:' in filters
    and 'flowMetadataReady' in filters,
)
require(
    'category_settings_screen_and_api',
    "import SettingsScreen from './screens/SettingsScreen.jsx'" in app
    and "activeScreen === 'settings'" in app
    and 'SettingsPortal' not in main
    and 'updateCategory' in api
    and 'updateCategory({' in settings
    and '<option value="expense">Расход</option>' in settings
    and '<option value="income">Приход</option>' in settings
    and "'api/v1/categories'" in category_workflow
    and 'category_update_v1' in category_workflow,
)
require(
    'settings_can_correct_unset_flow_after_backend_capability',
    "typeof category.editable === 'boolean'" in settings
    and '!sourceFlow && <option value="">Не задан</option>' in settings
    and 'flowOf(category) && typeof category.editable' not in settings,
)
require(
    'settings_sections_are_collapsed_by_default',
    'useState(null)' in settings
    and 'Управление защитой' in settings
    and 'Управление категориями' in settings
    and "openSection === 'security'" in settings
    and "openSection === 'categories'" in settings
    and 'document.addEventListener' not in settings,
)
require(
    'text_and_voice_ingress_starts_with_current_time',
    quick_workflow.count('message_date: Math.floor(Date.now()/1000)') >= 3,
)
require(
    'voice_ingress_time_survives_text_delegation',
    "$('Voice Prepare').first().json.message_date" in quick_time_patch
    and "changed_node={VOICE_TO_TEXT}" in quick_time_patch
    and 'graph_topology=UNCHANGED' in quick_time_patch,
)
require(
    'text_write_uses_ingress_epoch_not_midnight',
    text_write.count("$('MoneyTrack Transaction Processor Text').first().json.message_date") >= 4
    and 'to_timestamp(' in text_write
    and "'HH24:MI:SS'" in text_write
    and 'parsed_date_plus_ingress_clock_or_ingress_timestamp' in text_write
    and "current_date\n    )::timestamptz" not in text_write,
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
require(
    'backend_6_8_has_read_only_runtime_forensic',
    'READ_ONLY / NO_DB_OR_N8N_MUTATION' in backend_forensic
    and 'photo_parser_time_contract=' in backend_forensic
    and 'category_flow_unresolved_after_safe_inference=' in backend_forensic
    and 'DB_MUTATION=NONE' in backend_forensic
    and 'N8N_MUTATION=NONE' in backend_forensic,
)

print('UX022R3_REFERENCE_SETTINGS_GATE=PASS')
