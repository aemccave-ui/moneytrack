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
summary_runtime = read('miniapp/src/ux022r3-reference-runtime.js')
summary_css = read('miniapp/src/ux022r3-reference-runtime.css')
main = read('miniapp/src/main.jsx')
hero = read('miniapp/src/BalanceHero.jsx')
explorer = read('miniapp/src/AccountsExplorer.jsx')

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
    'home_snapshot_effect_is_async_keyed',
    "useState({ key: '', payload: null, error: '' })" in app
    and 'const homeSnapshotRequest = useMemo(() =>' in app
    and 'homeSnapshotState.key === homeSnapshotRequest?.key' in app
    and '.then((result) => setHomeSnapshotState({' in app
    and 'setHomeSnapshot(null)' not in app
    and "setHomeSnapshotError('')" not in app,
)
require(
    'home_group_totals_are_descendant_leaf_only',
    'const totalBase = children.length' in app
    and '? children.reduce((sum, child) => sum + child.totalBase, 0)' in app,
)
require(
    'summary_badge_is_single_and_first',
    "document.querySelectorAll('.stackNamedCaption')" in summary_runtime
    and "caption.querySelectorAll(':scope > .stackNamedItem')" in summary_runtime
    and "caption.querySelector(':scope > .summaryCountBadge')" in summary_runtime
    and "caption.prepend(badge)" in summary_runtime
    and "badge.textContent = count" in summary_runtime,
)
require(
    'per_name_summary_badges_are_hidden',
    '.stackNamedCaption > .stackNamedItem > .compactCountBadge{display:none!important}' in summary_css,
)
require(
    'expanded_home_badges_are_hidden',
    '.currencyDistribution .currencyHierarchy .homeCountBadge' in summary_css
    and '.accountDistribution .accountTree .homeCountBadge' in summary_css
    and 'display:none!important' in summary_css,
)
require(
    'summary_badge_runtime_loaded',
    "import './ux022r3-reference-runtime.js'" in main
    and "import './ux022r3-reference-runtime.css'" in main,
)
require(
    'home_reconciliation_fails_closed',
    'const homeTotalsMismatch = homeSnapshotComplete' in app
    and 'Math.abs(canonicalLeafTotal - canonicalNetWorth) > 0.02' in app
    and 'Остатки не согласованы с общим балансом' in app,
)
require(
    'summary_totals_round_without_losing_detail_cents',
    'money(Math.round(Number(value || 0)), baseCurrency)' in hero
    and 'money(Math.round(displayedTotal), displayCurrency)' in explorer
    and 'money(summary.result, currency)' in explorer
    and 'money(summary.income, currency)' in explorer
    and 'money(summary.expense, currency)' in explorer,
)

print('UX022R3_COUNT_BADGES_GATE=PASS')
