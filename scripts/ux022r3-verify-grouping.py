#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"UX022R3_GROUPING_GATE=FAIL check={name}")


contract = read("docs/architecture/UX-022-grouping-accounts-contract.md")
migration = read("db/domain/UX-022/040_grouping_account_invariant.sql")
rollback = read("db/domain/UX-022/990_rollback_code.sql")
renderer = read("scripts/ux022-render-migration.sh")
tree = read("miniapp/src/AccountTree.jsx")

require(
    "contract_operational_vs_grouping",
    "operational account" in contract
    and "grouping account" in contract
    and "MUST NOT have children" in contract
    and "MUST NOT have direct transactions/transfers" in contract,
)
require(
    "legacy_parent_history_moves_to_same_currency_leaf",
    "upper(child.currency_code) = v_parent.currency_code" in migration
    and "not moneytrack.ux022_account_has_active_children_v1(child.user_id, child.id)" in migration
    and "set account_id = v_target_id" in migration
    and "set from_account_id = v_target_id" in migration
    and "set to_account_id = v_target_id" in migration,
)
require(
    "legacy_target_is_unambiguous",
    "ACCOUNT_GROUPING_MIGRATION_TARGET_MISSING" in migration
    and "ACCOUNT_GROUPING_MIGRATION_TARGET_AMBIGUOUS" in migration
    and "v_target_count > 1" in migration,
)
require(
    "legacy_financial_conflicts_fail_closed",
    "ACCOUNT_GROUPING_MIGRATION_WOULD_COLLAPSE_TRANSFER" in migration
    and "ACCOUNT_GROUPING_MIGRATION_OPENING_BALANCE_CONFLICT" in migration,
)
require(
    "legacy_move_is_journaled",
    "ux022_grouping_transaction_migration_backup" in migration
    and "ux022_grouping_transfer_migration_backup" in migration
    and "original_account_id" in migration
    and "original_from_account_id" in migration
    and "original_to_account_id" in migration,
)
require(
    "legacy_move_is_rollbackable",
    "ux022_grouping_transaction_migration_backup" in rollback
    and "set account_id = b.original_account_id" in rollback
    and "set from_account_id = b.original_from_account_id" in rollback
    and "to_account_id = b.original_to_account_id" in rollback,
)
require(
    "parent_with_operations_forbidden_db",
    "ux022_account_has_direct_operations_v1" in migration
    and "ux022_accounts_parent_group_guard" in migration
    and "ACCOUNT_PARENT_HAS_OPERATIONS" in migration,
)
require(
    "restore_child_rechecks_parent_invariant",
    "update of parent_id, is_active" in migration
    and "not coalesce(new.is_active, true)" in migration,
)
require(
    "group_posting_forbidden_transactions",
    "ux022_transactions_group_posting_guard" in migration
    and "ux022_guard_transaction_postable_account_v1" in migration
    and "ACCOUNT_GROUP_NOT_POSTABLE" in migration,
)
require(
    "group_posting_forbidden_transfers",
    "ux022_transfers_group_posting_guard" in migration
    and "ux022_guard_transfer_postable_accounts_v1" in migration,
)
require(
    "grouping_migration_rendered",
    "040_grouping_account_invariant.sql" in renderer,
)
require(
    "grouping_invariant_rollback",
    "drop trigger if exists ux022_accounts_parent_group_guard" in rollback
    and "drop trigger if exists ux022_transactions_group_posting_guard" in rollback
    and "drop trigger if exists ux022_transfers_group_posting_guard" in rollback,
)
require(
    "parent_no_own_amount_ui",
    "ownAmount" not in tree
    and "accountOwnAmount" not in tree
    and "resolveOwnAmount" not in tree,
)
require(
    "parent_body_not_operational",
    "const bodyInteractive = !hasChildren" in tree,
)
require(
    "parent_operations_never_render",
    "const details = !hasChildren" in tree,
)
require(
    "parent_accordion_children_only",
    "Свернуть группу счетов" in tree
    and "Раскрыть группу счетов" in tree
    and "data-account-role={hasChildren ? 'group' : 'operational'}" in tree,
)

print("UX022R3_GROUPING_GATE=PASS")
