#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R3_FUNCTIONAL_GATE=FAIL check={name}")


swipe = read('miniapp/src/SwipeReveal.jsx')
recent = read('miniapp/src/RecentOperations.jsx')
editor = read('miniapp/src/TransactionEditor.jsx')
api = read('miniapp/src/api.js')
errors = read('miniapp/src/api-errors.js')
quick = read('miniapp/src/quick-actions-runtime.js')
drag = read('miniapp/src/account-drag-ghost-runtime.js')
main = read('miniapp/src/main.jsx')
nav = read('miniapp/packages/lab-design-system/navigation.jsx')
css = read('miniapp/src/ux022r3-frontend.css')
sql = read('db/domain/UX-022/050_transaction_editor_write.sql')
generator = read('scripts/ux022r3-generate-transaction-write-workflow.py')
quick_generator = read('scripts/ux022r3-generate-quick-input-workflow.py')

require(
    'habitstrack_pointer_swipe_model',
    'setPointerCapture' in swipe
    and 'Math.abs(dx) < 7 || Math.abs(dx) <= Math.abs(dy)' in swipe
    and 'width * .34' in swipe
    and 'translate3d(${effectiveX}px,0,0)' in swipe
    and 'overflow-x: auto' not in recent
    and "import { SwipeReveal }" in recent,
)
require(
    'single_global_swipe_and_2s_close',
    'announceSwipeOpen(key)' in swipe
    and 'SWIPE_OPEN_EVENT' in swipe
    and 'autoCloseMs = 2000' in swipe,
)
require(
    'transfer_actions_explained_and_protected',
    "disabled: transfer" in recent
    and 'Перевод связан с двумя счетами' in recent
    and 'transactionTransferReason' in recent,
)
require(
    'account_drag_has_floating_ghost',
    "cloneNode(true)" in drag
    and 'accountDragGhost' in drag
    and '--drag-x' in css
    and "import './account-drag-ghost-runtime.js'" in main,
)
require(
    'user_facing_domain_errors',
    "import { MoneyTrackApiError }" in api
    and 'DOMAIN_ERROR' in errors
    and 'ACCOUNT_GROUP_NOT_POSTABLE' in errors
    and 'TEXT_REQUIRED' in errors
    and 'PHOTO_BINARY_MISSING' in errors
    and 'VOICE_BINARY_MISSING' in errors
    and 'throw new MoneyTrackApiError' in api,
)
require(
    'nav_stats_before_budgets',
    "stats: 2" in nav and "budgets: 3" in nav,
)
require(
    'quick_photo_text_audio_handlers_restored',
    'api/v1/transaction/photo' in api
    and 'api/v1/transaction/text' in api
    and 'api/v1/transaction/voice' in api
    and 'body: { text }' in api
    and 'MediaRecorder' in quick
    and 'createTransactionFromPhoto' in quick
    and 'createTransactionFromText' in quick
    and 'createTransactionFromVoice' in quick
    and "import './quick-actions-runtime.js'" in main,
)
require(
    'quick_input_ingress_wrappers',
    'UX022QuickInput202608' in quick_generator
    and "api/v1/transaction/photo" in quick_generator
    and "api/v1/transaction/text" in quick_generator
    and "api/v1/transaction/voice" in quick_generator
    and 'moneytrackVerifyTelegramInitData' in quick_generator
    and "PHOTO_PROCESSOR_ID = '5VC0EcFB21rwTfoI'" in quick_generator
    and "TEXT_PROCESSOR_ID = 'f5ioJKyPTupUMV9h'" in quick_generator
    and "VOICE_PROCESSOR_ID = 'Td7kvvrtqQK0FTJg'" in quick_generator,
)
require(
    'quick_input_binary_passthrough',
    "const binary = auth.binary || {};" in quick_generator
    and "PHOTO_BINARY_MISSING" in quick_generator
    and "VOICE_BINARY_MISSING" in quick_generator
    and "binary\n}];" in quick_generator
    and "Voice Text Processor" in quick_generator,
)
require(
    'quick_input_no_duplicate_media_logic',
    'n8n-nodes-base.telegram' not in quick_generator
    and '@n8n/n8n-nodes-langchain.openAi' not in quick_generator
    and 'receipt_ingest_v1' not in quick_generator
    and 'finance_create_transaction_v1' not in quick_generator,
)
require(
    'transaction_editor_save_enabled',
    'createTransaction(' in editor
    and 'updateTransaction(' in editor
    and "type=\"submit\"" in editor
    and 'Сохранить · скоро' not in editor
    and "setEditor({ operation: tx, mode: 'repeat' })" in recent
    and "setEditor({ operation: tx, mode: 'edit' })" in recent,
)
require(
    'transaction_edit_domain_boundary',
    'finance_update_transaction_v1' in sql
    and 'TRANSACTION_TRANSFER_EDIT_UNSUPPORTED' in sql
    and 'ACCOUNT_GROUP_NOT_POSTABLE' in sql
    and 'finance_fx_convert_usd_bridge_v1' in sql,
)
require(
    'transaction_write_thin_adapter',
    'UX022TxWrite202608' in generator
    and "'POST'" in generator
    and "'PATCH'" in generator
    and 'finance_create_transaction_v1' in generator
    and 'finance_update_transaction_v1' in generator
    and 'insert into ' not in generator.lower()
    and 'update moneytrack.' not in generator.lower()
    and 'delete from ' not in generator.lower(),
)
require(
    'transaction_write_resolves_internal_user_id',
    'INTERNAL_USER_ID_SQL' in generator
    and 'from moneytrack.app_users u' in generator
    and 'where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint' in generator
    and 'finance_create_transaction_v1(\n  {{ $json.telegram_user_id }}' not in generator
    and 'finance_update_transaction_v1(\n  {{ $json.telegram_user_id }}' not in generator,
)

print('UX022R3_FUNCTIONAL_GATE=PASS')
