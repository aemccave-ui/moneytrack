#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R1_REGRESSION_GATE=FAIL check={name}")


app = read("miniapp/src/App.jsx")
main = read("miniapp/src/main.jsx")
telegram_guard = read("miniapp/src/telegram-interaction-guard.js")
recent = read("miniapp/src/RecentOperations.jsx")
recent_css = read("miniapp/src/recent-operations.css")
account_tree = read("miniapp/src/AccountTree.jsx")
accounts_css = read("miniapp/src/accounts-explorer.css")
create_sheet = read("miniapp/src/AccountCreateSheet.jsx")
explorer = read("miniapp/src/AccountsExplorer.jsx")
api = read("miniapp/src/api.js")
navigation = read("miniapp/packages/lab-design-system/navigation.jsx")

require(
    "home_screen_scroll_guard_native",
    "./telegram-interaction-guard.js" in main
    and "SCROLL_LOCK_MS = 1400" in telegram_guard
    and "scrollIntoView" in telegram_guard
    and "window.requestAnimationFrame(scrollLockTick)" in telegram_guard
    and "window.addEventListener('pageshow'" in telegram_guard
    and "document.addEventListener('visibilitychange'" in telegram_guard
    and "data-nav-id={item.id}" in navigation,
)
require(
    "telegram_vertical_swipe_conflict_guard",
    "disableVerticalSwipes?.()" in telegram_guard,
)
require(
    "operation_swipe_pointer_fallback",
    "setPointerCapture?.(event.pointerId)" in recent
    and "transactionSwipeShell ${actionsOpen ? 'actionsOpen' : ''} ${dragX < 0 ? 'isSwiping' : ''}" in recent,
)
require(
    "operation_swipe_native_touch_path",
    "row.addEventListener('touchstart', start, { passive: true })" in recent
    and "row.addEventListener('touchmove', move, { passive: false })" in recent
    and "row.addEventListener('touchend', end, { passive: true })" in recent
    and "onTouchStart=" not in recent
    and "nativeTouchHandlers.current =" not in recent
    and "SWIPE_THRESHOLD = 28" in recent,
)
require(
    "operation_swipe_touch_action",
    "touch-action:pan-y" in recent_css
    and "overscroll-behavior-x:contain" in recent_css
    and ".transactionSwipeShell.actionsOpen .transactionSwipeActions" in recent_css
    and "opacity:0;pointer-events:none" in recent_css,
)
require(
    "account_action_layers_hidden",
    ".accountSwipeShell.actionsOpen .accountSwipeActions" in accounts_css
    and "background:#fff" in accounts_css
    and "opacity:0;pointer-events:none" in accounts_css,
)
require(
    "account_swipe_pointer_fallback",
    "setPointerCapture?.(event.pointerId)" in account_tree
    and "ACTION_REVEAL = 220" in account_tree,
)
require(
    "account_swipe_native_touch_path",
    "row.addEventListener('touchstart', start, { passive: true })" in account_tree
    and "row.addEventListener('touchmove', move, { passive: false })" in account_tree
    and "row.addEventListener('touchend', end, { passive: true })" in account_tree
    and "onTouchStart=" not in account_tree
    and "nativeTouchHandlers.current =" not in account_tree
    and "SWIPE_THRESHOLD = 28" in account_tree
    and "overscroll-behavior-x:contain" in accounts_css,
)
require(
    "account_drag_target_ref_safe",
    "dragTarget: null" in account_tree
    and "press.current.dragTarget = target" in account_tree
    and "const target = press.current.dragTarget" in account_tree,
)
require(
    "account_move_explicit_sheet",
    "function MoveAccountSheet" in account_tree
    and ">Переместить</button>" in account_tree
    and "Без родителя / верхний уровень" in account_tree
    and "onMoveAccount={handleMove}" in explorer,
)
require(
    "parent_operations_before_children",
    account_tree.find("      {details}\n      {hasChildren && isExpanded") >= 0,
)
require(
    "expanded_account_operations_own_only",
    "include_descendants: 'false'" in api
    and "setOptionalIdFilter(params, 'selected_account_ids', [accountId])" in api,
)
require(
    "accounts_plus_matches_global_fab",
    "<span>Счёт</span>" in app
    and "className=\"fab\"" in app
    and ".accountsPlusButton{display:none}" in accounts_css,
)
require(
    "account_create_reliable_sheet",
    "AccountCreateSheet" in app
    and "await createAccount" in create_sheet
    and "onSaved?.()" in create_sheet
    and "explorerInlineError" in create_sheet,
)

print("UX022R1_REGRESSION_GATE=PASS")
