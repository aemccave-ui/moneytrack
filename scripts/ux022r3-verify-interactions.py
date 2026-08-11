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
swipe = read('miniapp/src/SwipeReveal.jsx')
drag_ghost = read('miniapp/src/account-drag-ghost-runtime.js')
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
    'operation_swipe_habitstrack_pointer_model',
    "import { SwipeReveal }" in recent
    and 'setPointerCapture' in swipe
    and 'Math.abs(dx) < 7 || Math.abs(dx) <= Math.abs(dy)' in swipe
    and 'width * .34' in swipe
    and 'translate3d(${effectiveX}px,0,0)' in swipe
    and 'overflow-x: auto' not in recent
    and 'scrollLeft' not in recent,
)

require(
    'all_swipes_autoclose_2s_and_cross_close',
    'SWIPE_OPEN_EVENT' in coordinator
    and 'announceSwipeOpen' in tree
    and 'announceSwipeOpen(key)' in swipe
    and 'autoCloseMs = 2000' in swipe
    and 'window.addEventListener(SWIPE_OPEN_EVENT' in tree
    and 'window.addEventListener(SWIPE_OPEN_EVENT' in swipe,
)

require(
    'account_drag_card_follows_finger',
    'cloneNode(true)' in drag_ghost
    and 'accountDragGhost' in drag_ghost
    and 'positionGhost(touch.clientX, touch.clientY)' in drag_ghost
    and '.accountDragGhost' in css
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
