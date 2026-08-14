#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R3_ACCOUNT_POLISH_GATE=FAIL check={name}")


tree = read('miniapp/src/AccountTree.jsx')
css = read('miniapp/src/ux022r3-selectors.css')

require(
    'group_selection_derived_from_operational_descendants',
    'function selectableIds(node)' in tree
    and "if (!node.children.length) return [accountId(node.account)]" in tree
    and 'return node.children.flatMap(selectableIds)' in tree
    and 'const ids = selectableIds(node)' in tree,
)

require(
    'group_subtitle_removed',
    'Группа ·' not in tree
    and "!hasChildren && <span className=\"accountTreeMeta\"" in tree,
)

require(
    'group_count_badge_inline_habitstrack_pattern',
    'accountTreeTitleRow' in tree
    and 'accountGroupCountBadge' in tree
    and '{node.children.length}' in tree
    and '.accountGroupCountBadge' in css
    and 'min-width: 22px;' in css
    and 'height: 22px;' in css
    and 'border-radius: 999px;' in css
    and 'font-variant-numeric: tabular-nums;' in css,
)

print('UX022R3_ACCOUNT_POLISH_GATE=PASS')
