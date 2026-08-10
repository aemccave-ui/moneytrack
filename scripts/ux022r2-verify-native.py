#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R2_STRUCTURAL_GATE=FAIL check={name}")


app = read("miniapp/src/App.jsx")
main = read("miniapp/src/main.jsx")
index_html = read("miniapp/index.html")
recent = read("miniapp/src/RecentOperations.jsx")
account_tree = read("miniapp/src/AccountTree.jsx")
api = read("miniapp/src/api.js")
css = read("miniapp/src/ux022r2-native.css")
currency_layout = read("miniapp/src/currency-layout.css")
create_sheet = read("miniapp/src/AccountCreateSheet.jsx")

require(
    "home_uses_dom_order_not_flex_order",
    "display: block" in currency_layout
    and "order:" not in currency_layout,
)
require(
    "home_dom_sequence",
    app.find('className="balanceHeader"')
    < app.find("<BalanceHero")
    < app.find("balanceBreakdownSection")
    < app.find("accountsSection compactSectionStart")
    < app.find("<RecentOperations"),
)
require(
    "no_custom_operation_gesture_engine",
    "onPointerDown=" not in recent
    and "onPointerMove=" not in recent
    and "onTouchStart=" not in recent
    and "addEventListener('touch" not in recent,
)
require(
    "operation_browser_native_free_scroll",
    "transactionSwipeTrack" in recent
    and "overflow-x: auto !important" in css
    and "scroll-snap-type:" not in css
    and ".transactionSwipeActions" in css
    and "position: static !important" in css,
)
require(
    "no_custom_account_gesture_engine",
    "onPointerDown=" not in account_tree
    and "onPointerMove=" not in account_tree
    and "onTouchStart=" not in account_tree
    and "addEventListener('touch" not in account_tree
    and "setPointerCapture" not in account_tree,
)
require(
    "account_browser_native_free_scroll",
    "accountSwipeTrack" in account_tree
    and ".accountSwipeShell" in css
    and ".accountSwipeTrack" in css
    and "grid-template-columns: calc(100% - 220px) 220px" in css
    and "scroll-snap-stop" not in css,
)
require(
    "screen_scroll_isolation",
    'key="home"' in app
    and 'key="accounts"' in app
    and "height: 100dvh" in css
    and "overflow-y: auto" in css
    and "window.scrollTo" not in app
    and "scrollRestoration" not in app,
)
require(
    "account_move_independent_path",
    "function MoveAccountSheet" in account_tree
    and "accountMoveShortcut" in account_tree
    and "Без родителя / верхний уровень" in account_tree
    and ">Переместить</button>" in account_tree,
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
    "accounts_global_fab_and_create_sheet",
    "AccountCreateSheet" in app
    and "<span>Счёт</span>" in app
    and "className=\"fab\"" in app
    and "await createAccount" in create_sheet
    and "onSaved?.()" in create_sheet
    and ".accountsPlusButton" in css
    and "display: none !important" in css,
)
require(
    "preview_build_identity_marker",
    'content="UX022R2.1"' in index_html
    and 'content: "R2.1"' in css
    and 'http-equiv="Cache-Control"' in index_html,
)
require(
    "native_override_loaded_last",
    "./ux022r2-native.css" in main
    and main.find("./ux022r2-native.css") > main.find("./accounts-explorer.css"),
)

print("UX022R2_STRUCTURAL_GATE=PASS")
print("UX022R2_STRUCTURAL_GATE_SCOPE=NOT_RUNTIME_ACCEPTANCE")
