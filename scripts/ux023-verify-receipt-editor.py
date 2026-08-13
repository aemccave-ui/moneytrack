#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

api = (ROOT / 'miniapp/src/api.js').read_text(encoding='utf-8')
recent = (ROOT / 'miniapp/src/RecentOperations.jsx').read_text(encoding='utf-8')
modal = (ROOT / 'miniapp/src/ReceiptModal.jsx').read_text(encoding='utf-8')
main = (ROOT / 'miniapp/src/main.jsx').read_text(encoding='utf-8')
sql = (ROOT / 'db/domain/UX-023/010_receipt_editor.sql').read_text(encoding='utf-8')
generator = (ROOT / 'scripts/ux023-generate-receipt-editor-workflow.py').read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f'UX023_RECEIPT_EDITOR=FAIL check={name}')
    print(f'check={name}=PASS')


require('tap_fetches_receipt', 'getReceiptByTransaction(tx.id)' in recent and '<ReceiptModal' in recent)
require('receipt_edit_cannot_bypass_modal', "mode === 'edit'" in recent and 'setReceiptView({ transaction: tx, receipt: lookup.receipt })' in recent)
require('non_receipt_fallback_preserved', 'setExpandedId((current) => current === id ? null : id)' in recent)
require('receipt_amount_uses_parent_transaction', 'transaction.amount_original' in modal and 'receipt?.total_amount' in modal)
require('only_currency_and_category_controls', 'updateReceiptCurrency' in modal and 'updateReceiptItemCategory' in modal and 'type="text"' not in modal and 'type="number"' not in modal)
require('receipt_scroll_surface', 'receiptItems' in modal and "import './receipt-modal.css'" in main)
require('api_paths', all(path in api for path in ['api/v1/receipt?transaction_id=', 'api/v1/receipt/currency', 'api/v1/receipt-item/category']))
require('owned_receipt_read_model', 'api_receipt_detail_read_model_v1' in sql and 'join user_ctx uc on uc.internal_user_id = r.user_id' in sql and 'u.telegram_user_id = p_telegram_user_id' in sql)
require('currency_boundary', 'receipt_set_currency_v1' in sql and 'DEFAULT_ACCOUNT_FOR_CURRENCY_NOT_FOUND' in sql and 'finance_fx_convert_usd_bridge_v1' in sql)
require('category_boundary', 'receipt_set_item_category_v2' in sql and 'product_catalog' in sql and 'transaction_category_id' in sql)
require('immutable_parser_fields', 'set shop_name' not in sql.lower() and 'set total_amount' not in sql.lower() and 'set transaction_date' not in sql.lower())
require('canonical_auth_fragment', 'api-3-telegram-initdata-verifier.fragment.js' in generator)
require('workflow_routes', all(path in generator for path in ["'api/v1/receipt'", "'api/v1/receipt/currency'", "'api/v1/receipt-item/category'"]))

print('UX023_RECEIPT_EDITOR=PASS')
