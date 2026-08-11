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
main = read('miniapp/src/main.jsx')

require(
    'account_group_badge_source_present',
    'className="accountGroupCountBadge"' in tree
    and '>{node.children.length}</span>' in tree,
)
require(
    'badges_use_muted_page_palette',
    'UX022R3_COUNT_BADGE_CONTRACT' in css
    and 'background: rgba(220,235,236,.9);' in css
    and 'color: #1d5559;' in css
    and 'border: 1px solid rgba(29,85,89,.16);' in css,
)
require(
    'home_account_structure_deduplicated',
    'function flattenAccounts(accounts = [])' in app
    and 'const byId = new Map()' in app
    and 'byId.set(id, existing ? { ...existing, ...normalized } : normalized)' in app
    and 'return [...byId.values()]' in app,
)
require(
    'home_uses_canonical_snapshot_read_model',
    'getAccountsExplorerSummary' in app
    and 'homeSnapshot?.account_balances' in app
    and 'balance_original: Number(snapshot.balance_original ?? 0)' in app
    and 'balance_base: Number(snapshot.balance_base ?? 0)' in app,
)
require(
    'home_structural_scope_is_leaf_only',
    'const structuralLeafItems = useMemo(() =>' in app
    and 'return accountItems.filter((account) => !parentIds.has(accountId(account)))' in app
    and 'selectedAccountIds = structuralLeafItems.map(accountId)' in app,
)
require(
    'home_group_totals_are_descendant_leaf_only',
    'const totalBase = children.length' in app
    and '? children.reduce((sum, child) => sum + child.totalBase, 0)' in app
    and 'const leafCount = children.length' in app
    and '? children.reduce((sum, child) => sum + child.leafCount, 0)' in app,
)
require(
    'compact_home_summaries_have_per_name_badges',
    'function HomeNamedSummary({ items, title })' in app
    and 'className="stackNamedItem"' in app
    and 'className="homeCountBadge compactCountBadge"' in app
    and 'count: group.accounts.length' in app
    and 'count: node.leafCount' in app
    and '.stackNamedCaption {' in css
    and '.app .compactCountBadge {' in css,
)
require(
    'home_currency_badge_is_direct_named_markup',
    'className="homeNamedAggregate"' in app
    and 'className="currencyBadge">{group.currency}</span>' in app
    and '>{group.accounts.length}</span>' in app,
)
require(
    'home_account_badge_is_direct_named_markup',
    'className="homeAggregateTitleRow"' in app
    and '>{node.leafCount}</span>' in app
    and '.homeAggregateTitleRow > .homeCountBadge' in css,
)
require(
    'single_item_badges_remain_visible',
    'if (count <= 1)' not in app
    and 'if (count <= 1)' not in css
    and 'group.accounts.length > 1' not in app
    and 'node.leafCount > 1' not in app,
)
require(
    'grouping_second_line_removed_on_home',
    '!hasChildren && <span className="accountTreeMeta">' in app,
)
require(
    'stack_level_count_badges_removed',
    'stackCount' not in app,
)
require(
    'home_badges_are_not_dom_mutated',
    "import './currency-summary.js'" not in main
    and 'MutationObserver' not in app,
)
require(
    'home_reconciliation_fails_closed',
    'const homeTotalsMismatch = homeSnapshotComplete' in app
    and 'Math.abs(canonicalLeafTotal - canonicalNetWorth) > 0.02' in app
    and 'Остатки не согласованы с общим балансом' in app,
)
require(
    'home_currency_row_uses_three_columns',
    '.currencyDistribution .currencyGroupHeader {' in css
    and 'grid-template-columns: 22px minmax(0,1fr) auto;' in css,
)

print('UX022R3_COUNT_BADGES_GATE=PASS')
