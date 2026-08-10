#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(name: str, condition: bool) -> None:
    print(f"{name}={'PASS' if condition else 'FAIL'}")
    if not condition:
        raise SystemExit(f"SOURCE_GATE=FAIL check={name}")


explorer = read("miniapp/src/AccountsExplorer.jsx")
tree = read("miniapp/src/AccountTree.jsx")
filters = read("miniapp/src/AccountsFilters.jsx")
recent = read("miniapp/src/RecentOperations.jsx")
api = read("miniapp/src/api.js")
presets_sql = read("db/domain/UX-022/010_filter_presets.sql")
lifecycle_sql = read("db/domain/UX-022/020_account_lifecycle.sql")
lifecycle_hardening_sql = read("db/domain/UX-022/025_account_lifecycle_hardening.sql")
read_models_sql = read("db/domain/UX-022/030_accounts_explorer_read_models.sql")
read_models_hardening_sql = read("db/domain/UX-022/035_accounts_explorer_read_model_hardening.sql")
reference_inventory_sql = read("db/domain/UX-022/905_reference_inventory.sql")
rollback_sql = read("db/domain/UX-022/990_rollback_code.sql")
generator = read("scripts/ux022-generate-api-workflows.py")
renderer = read("scripts/ux022-render-migration.sh")
migration_gate = read("scripts/ux022-migration-gate.sh")
deployer = read("scripts/ux022-deploy-preview.sh")
auth = read("scripts/api-3-telegram-initdata-verifier.fragment.js")

require("collapsed_default", "useState(() => new Set())" in explorer and "accountsExplorer.expanded" not in explorer)
require("date_before_filters", explorer.index("period === 'range'") < explorer.index("<AccountsFilters"))
require("parent_own_display", "resolveOwnAmount" in explorer and "fullSubtreeTotal" in explorer)
require(
    "tri_state_selection",
    "return 'partial'" in tree
    and "className={`accountSelectionControl is-${state}`}" in tree
    and "data-selection-state={state}" in tree,
)
require("category_circle_semantics", "categoryCircle" in filters and "isOn" in filters)
require("system_preset_all", "Системный пресет" in filters and ">Все<" in filters)
require("drag_long_press_600ms", "setTimeout(() =>" in tree and "}, 600)" in tree)
require("drag_cycle_front_guard", "ACCOUNT_HIERARCHY_CYCLE" in explorer)
require("swipe_autoclose_accounts_2000", "setTimeout(() => onActionsClose?.(id), 2000)" in tree)
require("swipe_autoclose_home_2000", "setTimeout(onActionsClose, 2000)" in recent)
require("accounts_plus", "accountsPlusButton" in explorer and "Добавить новый счёт" in explorer)
require("archive_restore_ui", "ArchivedAccountsSheet" in explorer and "restoreAccount" in explorer)
require("move_preview_ui", "previewMoveAccountOperations" in explorer and "Будет перенесено" in explorer)
require("immutable_preset_frontend", "createFilterPreset" in filters and "renameFilterPreset" in filters and "date_from" not in filters and "date_to" not in filters)
require("immutable_preset_backend", "filter_preset_create_v1" in presets_sql and "filter_preset_rename_v1" in presets_sql and "p_date_from" not in presets_sql and "p_date_to" not in presets_sql)
require("legacy_preset_shape_fail_closed", "UX022_FILTER_PRESETS_LEGACY_SHAPE_INCOMPATIBLE" in presets_sql)
require("copy_code_independent", "v_source.code ||" not in lifecycle_hardening_sql and "v_code := 'account_'" in lifecycle_hardening_sql)
require(
    "schema_tolerant_default_guard",
    "ux022_account_is_default_v1" in lifecycle_hardening_sql
    and "jsonb_each_text(to_jsonb(s))" in lifecycle_hardening_sql
    and "to_regclass('moneytrack.user_default_accounts')" in lifecycle_hardening_sql
    and "UX022_DEFAULT_ACCOUNT_REFERENCE_SHAPE_UNKNOWN" in lifecycle_hardening_sql,
)
require(
    "archive_delete_use_default_guard",
    lifecycle_hardening_sql.count("moneytrack.ux022_account_is_default_v1(v_user_id, p_account_id)") >= 2,
)
require(
    "reference_inventory_classifies_user_settings",
    "c.table_name = 'user_settings' and c.column_name like '%account_id%'" in reference_inventory_sql,
)
require(
    "rollback_drops_default_guard",
    "drop function if exists moneytrack.ux022_account_is_default_v1(bigint,bigint);" in rollback_sql,
)

snapshot_chunk = read_models_sql.split("transaction_movements as", 1)[1].split("period_transactions as", 1)[0]
require("snapshot_independent_of_date_from", "p_date_from" not in snapshot_chunk and "p_as_of" in snapshot_chunk)
require("adjustment_is_expense", "transaction_type in ('expense','adjustment')" in read_models_sql)
require("internal_transfer_suppression", "((sa_from.id is not null) <> (sa_to.id is not null))" in read_models_sql)
require(
    "selected_snapshot_missing_rate_only",
    "join selected_accounts sa on sa.id = cb.account_id" in read_models_hardening_sql
    and "where cb.balance_base is null" in read_models_hardening_sql
    and "Full account snapshot is returned for the tree; total_base and snapshot_missing_rate_count are scoped only to selected accounts." in read_models_hardening_sql,
)
require("history_move_atomic_boundary", "account_move_operations_v1" in lifecycle_sql and "update moneytrack.transactions" in lifecycle_sql and "update moneytrack.transfers" in lifecycle_sql)
require("history_move_currency_guard", "ACCOUNT_CURRENCY_INCOMPATIBLE" in lifecycle_sql)
require("delete_no_transaction_cascade", "delete from moneytrack.transactions" not in lifecycle_sql.lower() and "delete from moneytrack.transfers" not in lifecycle_sql.lower())
require("archive_zero_balance", "ACCOUNT_BALANCE_NOT_ZERO" in lifecycle_sql and "account_archive_v1" in lifecycle_sql)
require("canonical_auth_contract", "api3b-v1" in auth and "api-3-telegram-initdata-verifier.fragment.js" in generator)
require("frontend_preview_does_not_name_prod", "app.moneytrackapp.xyz" not in api + explorer + tree + filters + recent)
require("preview_deployer_no_prod_target", "app.moneytrackapp.xyz" not in deployer)
require("runtime_uses_three_restorable_workflows", "UX022AccountLifecycle202608" not in deployer and deployer.count("export_workflow UX022") == 3)
require(
    "migration_validate_apply_same_body",
    "035_accounts_explorer_read_model_hardening.sql" in renderer
    and '"$ROOT/scripts/ux022-render-migration.sh"' in migration_gate
    and '"$ROOT/scripts/ux022-render-migration.sh"' in deployer,
)
require("runtime_preflight_before_mutation", "runtime_preflight=PASS" in deployer and deployer.index("runtime_preflight=PASS") < deployer.index("ux022-source-gate.sh"))

with tempfile.TemporaryDirectory(prefix="ux022-source-") as tmp:
    out = Path(tmp)
    subprocess.run([sys.executable, str(ROOT / "scripts/ux022-generate-api-workflows.py"), "--out-dir", str(out)], check=True)
    candidates = sorted(out.glob("*.candidate.json"))
    require("workflow_candidates_generated", len(candidates) == 4)

    merged = out / "ux022-presets-lifecycle.merged.json"
    subprocess.run([
        sys.executable,
        str(ROOT / "scripts/ux022-merge-lifecycle-into-presets.py"),
        "--presets", str(out / "ux022-presets.candidate.json"),
        "--lifecycle", str(out / "ux022-lifecycle.candidate.json"),
        "--output", str(merged),
    ], check=True)
    merged_workflow = json.loads(merged.read_text(encoding="utf-8"))
    require("merged_workflow_preserves_id", merged_workflow.get("id") == "UX022Presets202608")
    merged_names = [node.get("name") for node in merged_workflow.get("nodes", [])]
    require("merged_workflow_node_names_unique", len(merged_names) == len(set(merged_names)))
    merged_paths = {
        node.get("parameters", {}).get("path")
        for node in merged_workflow.get("nodes", [])
        if node.get("type") == "n8n-nodes-base.webhook"
    }
    require("merged_workflow_lifecycle_routes_present", {
        "api/v1/filter-presets",
        "api/v1/accounts",
        "api/v1/accounts/copy",
        "api/v1/accounts/move",
        "api/v1/accounts/archive",
        "api/v1/accounts/restore",
        "api/v1/accounts/archived",
        "api/v1/accounts/move-operations/preview",
        "api/v1/accounts/move-operations",
    }.issubset(merged_paths))

    runtime_candidates = [
        out / "ux022-transactions.candidate.json",
        out / "ux022-summary.candidate.json",
        merged,
    ]
    all_queries: list[str] = []
    for candidate in runtime_candidates:
        workflow = json.loads(candidate.read_text(encoding="utf-8"))
        for node in workflow.get("nodes", []):
            if node.get("type") == "n8n-nodes-base.postgres":
                query = node.get("parameters", {}).get("query", "")
                all_queries.append(query)
                require(f"thin_adapter_{candidate.stem}_{node['name']}", query.strip().lower().startswith("select * from moneytrack."))
    joined = "\n".join(all_queries).lower()
    require("thin_adapter_no_dml", not any(token in joined for token in ("insert into ", "update moneytrack.", "delete from ")))

print("SOURCE_GATE=PASS")
