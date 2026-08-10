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
recent = read("miniapp/src/RecentOperations.jsx")
recent_css = read("miniapp/src/recent-operations.css")
account_tree = read("miniapp/src/AccountTree.jsx")
accounts_css = read("miniapp/src/accounts-explorer.css")
create_sheet = read("miniapp/src/AccountCreateSheet.jsx")

require(
    "home_screen_scroll_reset",
    "function forceScrollTop()" in app
    and "window.history.scrollRestoration = 'manual'" in app
    and "document.scrollingElement.scrollTop = 0" in app
    and "[activeScreen, dashboardReady]" in app
    and "window.setTimeout(forceScrollTop, 260)" in app,
)
require(
    "operation_swipe_pointer_fallback",
    "setPointerCapture?.(event.pointerId)" in recent
    and "transactionSwipeShell ${actionsOpen ? 'actionsOpen' : ''} ${dragX < 0 ? 'isSwiping' : ''}" in recent,
)
require(
    "operation_swipe_touch_path",
    "onTouchStart={touchStart}" in recent
    and "onTouchMove={touchMove}" in recent
    and "onTouchEnd={touchEnd}" in recent
    and "event.pointerType === 'touch'" in recent,
)
require(
    "operation_swipe_touch_action",
    "touch-action:pan-y" in recent_css
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
    "account_swipe_touch_path",
    "onTouchStart={touchStart}" in account_tree
    and "onTouchMove={touchMove}" in account_tree
    and "onTouchEnd={touchEnd}" in account_tree
    and "event.pointerType === 'touch'" in account_tree,
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
    and "Без родителя / верхний уровень" in account_tree,
)
require(
    "parent_operations_before_children",
    account_tree.find("      {details}\n      {hasChildren && isExpanded") >= 0,
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
