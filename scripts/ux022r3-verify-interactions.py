#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R3_INTERACTION_GATE=FAIL check={name}")


tree = read('miniapp/src/AccountTree.jsx')
recent = read('miniapp/src/RecentOperations.jsx')
css = read('miniapp/src/ux022r3-frontend.css')
coordinator = read('miniapp/src/swipe-coordinator.js')

require(
    'account_swipe_icons_horizontal',
    '.accountSwipeActions .swipeActionButton' in css
    and 'flex-direction: row;' in css
    and 'writing-mode: horizontal-tb !important;' in css
    and 'transform: none !important;' in css
    and 'rotate: none !important;' in css,
)

require(
    'operation_swipe_deterministic_settle',
    'TRANSACTION_ACTIONS_WIDTH = 156' in recent
    and 'TRANSACTION_OPEN_THRESHOLD = 34' in recent
    and "addEventListener('touchend', settle" in recent
    and "shell.scrollTo({ left: TRANSACTION_ACTIONS_WIDTH, behavior: 'smooth' })" in recent
    and "shell.scrollTo({ left: 0, behavior: 'smooth' })" in recent
    and 'scroll-snap-type: none !important;' in css
    and 'onScroll={handleScroll}' not in recent,
)

require(
    'all_swipes_autoclose_2s_and_cross_close',
    'SWIPE_OPEN_EVENT' in coordinator
    and 'announceSwipeOpen' in tree
    and 'announceSwipeOpen' in recent
    and 'window.setTimeout(() => setOpenSwipeId(null), 2000)' in tree
    and 'window.setTimeout(() => setOpenSwipeId(null), 2000)' in recent
    and 'window.addEventListener(SWIPE_OPEN_EVENT' in tree
    and 'window.addEventListener(SWIPE_OPEN_EVENT' in recent,
)

require(
    'account_drag_card_follows_finger',
    'setDragOffset({ x: x - dragRef.current.startX, y: y - dragRef.current.startY })' in tree
    and 'translate3d(${dragOffset.x}px, ${dragOffset.y}px, 0)' in tree
    and 'document.elementsFromPoint' in tree
    and 'isDropTarget' in tree,
)

require(
    'account_drag_can_drop_to_root',
    "ROOT_DROP_TARGET = '__root__'" in tree
    and 'data-account-root-drop="true"' in tree
    and "targetId === ROOT_DROP_TARGET ? null : targetId" in tree
    and 'await onMoveAccount?.(sourceId, nextParentId)' in tree
    and '.accountRootDropZone.isDragRootZone' in css
    and 'В верхний уровень' in tree,
)

require(
    'excluded_account_muted_without_message',
    'isSelectionExcluded' in tree
    and '.accountTreeNode.isSelectionExcluded .accountTreeRow' in css
    and 'opacity: .46;' in css
    and '.accountTreeNode.isSelectionExcluded .explorerTransactionsLoading' in css
    and 'display: none;' in css,
)

print('UX022R3_INTERACTION_GATE=PASS')
