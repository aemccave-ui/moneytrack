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
migration_gate = read("scripts/ux022-migration-gate.sh")
runtime_verify = read("db/domain/UX-022/910_verify_grouping_invariant.sql")
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
    "upper(child.currency_code) = v_parent.currency_upper" in migration
    and "not moneytrack.ux022_account_has_active_children_v1(child.user_id, child.id)" in migration
    and "set account_id = v_target_id" in migration
    and "set from_account_id = v_target_id" in migration
    and "set to_account_id = v_target_id" in migration,
)
require(
    "legacy_target_deterministic_when_multiple",
    "order by coalesce(child.sort_order, 2147483647), child.id" in migration
    and "limit 1" in migration,
)
require(
    "legacy_target_skips_financial_conflicts",
    "tr.from_account_id = v_parent.id and tr.to_account_id = child.id" in migration
    and "t.transaction_type = 'openingbalance'" in migration,
)
require(
    "legacy_fallback_child_when_no_safe_target",
    "if v_target_id is null then" in migration
    and "ux022_grouping_created_account_migration_backup" in migration
    and "'r3_legacy_parent_' || v_parent.id::text" in migration
    and "v_parent.name || ' — операции'" in migration,
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
    "default_references_follow_operational_child",
    "ux022_grouping_user_default_migration_backup" in migration
    and "ux022_grouping_user_settings_migration_backup" in migration
    and "update moneytrack.user_default_accounts" in migration
    and "ACCOUNT_GROUPING_DEFAULT_REFERENCE_REMAINS" in migration,
)
require(
    "legacy_move_is_rollbackable",
    "ux022_grouping_transaction_migration_backup" in rollback
    and "set account_id = b.original_account_id" in rollback
    and "set from_account_id = b.original_from_account_id" in rollback
    and "to_account_id = b.original_to_account_id" in rollback
    and "ux022_grouping_created_account_migration_backup" in rollback
    and "UX022R3_ROLLBACK_FALLBACK_ACCOUNT_HAS_NEW_REFERENCES" in rollback,
)
require(
    "default_reference_move_is_rollbackable",
    "ux022_grouping_user_default_migration_backup" in rollback
    and "ux022_grouping_user_settings_migration_backup" in rollback,
)
require(
    "rollback_only_runtime_verification",
    "910_verify_grouping_invariant.sql" in migration_gate
    and "UX022R3_GROUPING_RUNTIME_VERIFY=PASS" in runtime_verify
    and "migrated_transactions" in runtime_verify
    and "migrated_transfers" in runtime_verify,
)
require(
    "parent_with_operations_forbidden_db",
    "ux022_account_has_direct_operations_v1" in migration
    and "ux022_accounts_parent_group_guard" in migration
    and "ACCOUNT_PARENT_HAS_OPERATIONS" in migration,
)
require(
    "default_parent_forbidden_db",
    "ACCOUNT_PARENT_IS_DEFAULT" in migration
    and "ux022_account_is_default_v1(new.user_id, new.parent_id)" in migration,
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
