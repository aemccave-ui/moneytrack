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
    'home_aggregates_use_leaf_accounts',
    'const operationalAccountItems = useMemo(() =>' in app
    and 'return accountItems.filter((account) => !parentIds.has(accountId(account)))' in app
    and 'operationalAccountItems.forEach((account) =>' in app
    and 'const totalBase = children.length' in app
    and '? children.reduce((sum, child) => sum + child.totalBase, 0)' in app,
)
require(
    'home_currency_badge_bound_to_named_row',
    'UX022R3_HOME_COUNT_BADGE_RUNTIME' in runtime
    and 'function enhanceCurrencyGroupBadges()' in runtime
    and "document.querySelectorAll('.currencyDistribution .currencyGroupHeader')" in runtime
    and "button.querySelector('.currencyBadge')" in runtime
    and "button.querySelector('.hierarchyCount, .homeCountBadge')" in runtime,
)
require(
    'home_account_badge_bound_to_named_row',
    'function enhanceHomeAccountBadges()' in runtime
    and "document.querySelectorAll('.accountDistribution .accountTreeRow.hasChildren')" in runtime
    and "titleRow.className = 'homeAggregateTitleRow'" in runtime
    and "badge = document.createElement('span')" in runtime
    and "titleRow.append(badge)" in runtime,
)
require(
    'single_item_badges_are_visible',
    'const next = String(count)' in runtime
    and 'badge.textContent = next' in runtime
    and 'if (count <= 1)' not in runtime,
)
require(
    'badge_observer_updates_are_idempotent',
    'if (badge.textContent !== next) badge.textContent = next' in runtime,
)
require(
    'home_count_removed_from_subline',
    "meta.textContent = meta.textContent.replace(/\\s*·\\s*\\d+\\s*$/, '').trim()" in runtime,
)
require(
    'home_badges_inline_after_name',
    'UX022R3_HOME_NAMED_COUNT_BADGES' in css
    and '.app .homeAggregateTitleRow > .homeCountBadge {' in css
    and 'order: 1;' in css,
)

print('UX022R3_COUNT_BADGES_GATE=PASS')
