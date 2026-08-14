#!/usr/bin/env python3
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

api = (ROOT / 'miniapp/src/api.js').read_text(encoding='utf-8')
# Receipt accounting client is part of the canonical common API module.
accounting_api = api
recent = (ROOT / 'miniapp/src/RecentOperations.jsx').read_text(encoding='utf-8')
modal = (ROOT / 'miniapp/src/ReceiptModal.jsx').read_text(encoding='utf-8')
main = (ROOT / 'miniapp/src/main.jsx').read_text(encoding='utf-8')
sql = (ROOT / 'db/domain/UX-023/010_receipt_editor.sql').read_text(encoding='utf-8')
hardening = (ROOT / 'db/domain/UX-023/020_receipt_accounting_hardening.sql').read_text(encoding='utf-8')
generator = (ROOT / 'scripts/ux023-generate-receipt-accounting-workflow.py').read_text(encoding='utf-8')
apply_path = ROOT / 'scripts/ux023-receipt-accounting-preview-apply.sh'
apply_script = apply_path.read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f'UX023_RECEIPT_EDITOR=FAIL check={name}')
    print(f'check={name}=PASS')


compile(generator, 'ux023-generate-receipt-accounting-workflow.py', 'exec')
subprocess.run(['bash', '-n', str(apply_path)], check=True)
require('tap_fetches_receipt', 'getReceiptByTransaction(tx.id)' in recent and '<ReceiptModal' in recent)
open_operation_start = recent.index("  const openOperation = async (tx) => {")
open_operation_end = recent.index("\n  const receiptChanged", open_operation_start)
open_operation = recent[open_operation_start:open_operation_end]

receipt_source_guard = "if (sourceKind === 'photo_receipt' || sourceKind == null) {"
receipt_modal_route = "if (lookup.receipt) { receiptRefreshPending.current = false; setReceiptView({ transaction: tx, receipt: lookup.receipt }); return }"
receipt_missing_guard = "if (sourceKind === 'photo_receipt') { showError('Источник операции — фото чека, но связанный чек не найден.'); return }"
generic_transaction_route = "setEditor({ operation: tx, mode: 'edit', kind: 'transaction' })"

require(
    'receipt_edit_cannot_bypass_modal',
    receipt_source_guard in open_operation
    and receipt_modal_route in open_operation
    and receipt_missing_guard in open_operation
    and generic_transaction_route in open_operation
    and open_operation.index(receipt_source_guard)
        < open_operation.index(receipt_modal_route)
        < open_operation.index(receipt_missing_guard)
        < open_operation.index(generic_transaction_route),
)
require(
    'non_receipt_fallback_preserved',
    generic_transaction_route in open_operation
    and 'setExpandedId(' not in recent
    and 'transactionDetails' not in recent,
)
require('receipt_amount_uses_parent_transaction', 'transaction.amount_original' in modal and 'receipt?.total_amount' in modal)
require('explicit_account_selector', 'getAccounts' in modal and 'receiptAccountSelect' in modal and 'Счёт учёта' in modal)
require('leaf_accounts_only', 'disabled: (_item, children) => children.length > 0' in modal)
require('account_currency_draft_pair', 'draftAccountId' in modal and 'draftCurrency' in modal and 'selectedAccountCurrency === draftCurrency' in modal)
require('inconsistent_save_blocked', 'accountingDirty && (!accountingConsistent || accountsLoading)' in modal and 'receiptAccountingMismatch' in modal)
require('atomic_accounting_client', 'updateReceiptAccounting' in modal and 'api/v1/receipt/accounting' in accounting_api and 'account_id' in accounting_api)
require('old_currency_only_client_not_used', 'updateReceiptCurrency' not in modal)
require('only_account_currency_and_category_controls', 'updateReceiptItemCategory' in modal and 'type="text"' not in modal and 'type="number"' not in modal)
require('receipt_scroll_surface', 'receiptItems' in modal and "import './receipt-modal.css'" in main)
require('receipt_read_api_preserved', 'api/v1/receipt?transaction_id=' in api)
require('owned_receipt_read_model', 'api_receipt_detail_read_model_v1' in sql and 'join user_ctx uc on uc.internal_user_id = r.user_id' in sql and 'u.telegram_user_id = p_telegram_user_id' in sql)
require('read_model_exposes_account', "'account_id', rr.account_id" in sql and "'account_currency', rr.account_currency" in sql)
require('atomic_accounting_boundary', 'receipt_update_accounting_v1' in sql and 'ACCOUNT_CURRENCY_MISMATCH' in sql and 'ACCOUNT_GROUP_NOT_POSTABLE' in sql and 'finance_fx_convert_usd_bridge_v1' in sql)
require('no_automatic_default_account', 'user_default_accounts' not in sql and 'DEFAULT_ACCOUNT_FOR_CURRENCY_NOT_FOUND' not in sql)
require('currency_only_boundary_removed', 'drop function if exists moneytrack.receipt_set_currency_v1(bigint,bigint,text)' in hardening)
require('category_boundary', 'receipt_set_item_category_v2' in sql and 'product_catalog' in sql and 'transaction_category_id' in sql)
require('immutable_parser_fields', 'set shop_name' not in sql.lower() and 'set total_amount' not in sql.lower() and 'set transaction_date' not in sql.lower())
require('canonical_auth_fragment', 'api-3-telegram-initdata-verifier.fragment.js' in generator)
require('workflow_routes', all(path in generator for path in ["'api/v1/receipt'", "'api/v1/receipt/accounting'", "'api/v1/receipt-item/category'"]))
require('workflow_accounting_boundary', 'receipt_update_accounting_v1' in generator and 'account_id' in generator)
require('controlled_apply_uses_new_generator', 'ux023-generate-receipt-accounting-workflow.py' in apply_script)
require('controlled_apply_hardens_currency_only_path', '020_receipt_accounting_hardening.sql' in apply_script and 'receipt_currency_only_write=ABSENT' in apply_script and 'old_currency_route_absent=PASS' in apply_script)
require('controlled_apply_preview_only', 'PRODUCTION_FRONTEND_MUTATION=NONE' in apply_script and 'PREVIEW_FRONTEND_MUTATION=APPLIED' in apply_script)

print('UX023_RECEIPT_EDITOR=PASS')
