#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R3_COUNT_BADGES_GATE=FAIL check={name}")


tree = read('miniapp/src/AccountTree.jsx')
app = read('miniapp/src/App.jsx')
css = read('miniapp/src/account-distribution.css')
runtime = read('miniapp/src/currency-summary.js')

require(
    'account_group_badge_source_present',
    'className="accountGroupCountBadge"' in tree
    and '>{node.children.length}</span>' in tree,
)
require(
    'account_group_badge_visually_before_name',
    'UX022R3_COUNT_BADGE_CONTRACT' in css
    and '.accountTreeTitleRow > .accountGroupCountBadge { order: -1; }' in css
    and '.accountTreeTitleRow > strong { order: 0; }' in css,
)
require(
    'badges_use_muted_page_palette',
    'background: rgba(220,235,236,.9);' in css
    and 'color: #1d5559;' in css
    and 'border: 1px solid rgba(29,85,89,.16);' in css,
)
require(
    'home_aggregate_sources_present',
    'currencyStackSegment' in app
    and 'accountStackSegment' in app
    and 'currencyStackButton' in app
    and 'accountStackButton' in app,
)
require(
    'home_count_badges_for_currency_and_accounts',
    "ensureCountBadge(button, '.currencyStackSegment', '.stackCaption', 'Валют')" in runtime
    and "ensureCountBadge(button, '.accountStackSegment', '.accountStackMeta', 'Счетов')" in runtime
    and "badge.className = 'stackCount'" in runtime
    and 'if (count <= 1)' in runtime,
)
require(
    'home_badges_visually_before_caption',
    '.stackCaption .stackCount,' in css
    and '.accountStackMeta .stackCount { order: -1; }' in css
    and 'display: flex;' in css,
)

print('UX022R3_COUNT_BADGES_GATE=PASS')
