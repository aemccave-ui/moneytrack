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


app = read("miniapp/src/App.jsx")
main = read("miniapp/src/main.jsx")
explorer = read("miniapp/src/AccountsExplorer.jsx")
tree = read("miniapp/src/AccountTree.jsx")
filters = read("miniapp/src/AccountsFilters.jsx")
recent = read("miniapp/src/RecentOperations.jsx")
swipe_reveal = read("miniapp/src/SwipeReveal.jsx")
api = read("miniapp/src/api.js")
create_sheet = read("miniapp/src/AccountCreateSheet.jsx")
currency_layout = read("miniapp/src/currency-layout.css")
frontend_css = read("miniapp/src/ux022r3-frontend.css")
gesture_policy = read("miniapp/src/telegram-gesture-policy.js")
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
require(
    "parent_aggregate_only",
    "fullSubtreeTotal" in explorer
    and "const details = !hasChildren" in tree
    and "accountOwnAmount" not in tree,
)
require(
    "tri_state_selection",
    "return 'partial'" in tree
    and "className={`accountSelectionControl is-${state}`}" in tree
    and "data-selection-state={state}" in tree,
)
require("category_circle_semantics", "categoryCircle" in filters and "isOn" in filters)
require("system_preset_all", "Системный пресет" in filters and ">Все<" in filters)
require(
    "home_dom_order_restored",
    ".app {\n  display: block;" in currency_layout
    and "order:" not in currency_layout
    and "window.scrollTo" not in app
    and 'key="home"' in app
    and 'key="accounts"' in app,
)
require(
    "responsive_operation_swipe_with_icons",
    "SwipeReveal" in recent
    and "SwipeActionIcon" in recent
    and "setPointerCapture" in swipe_reveal
    and "Math.abs(dx) < 7 || Math.abs(dx) <= Math.abs(dy)" in swipe_reveal
    and "width * .34" in swipe_reveal
    and "autoCloseMs = 2000" in swipe_reveal
    and "overflow-x: auto" not in recent
    and "disableVerticalSwipes" in gesture_policy,
)
require(
    "account_swipe_three_actions_with_icons",
    "accountSwipeTrack" in tree
    and tree.count('className="swipeActionButton') == 3
    and "<span>Изменить</span>" in tree
    and "<span>Архив</span>" in tree
    and "<span>Удалить</span>" in tree
    and "Копировать" not in tree
    and "MoveAccountSheet" not in tree
    and "accountMoveShortcut" not in tree
    and "grid-template-columns: repeat(3, 56px)" in frontend_css,
)
require(
    "account_long_press_drag_move",
    "}, 480)" in tree
    and "addEventListener('touchmove', touchMove, { passive: false })" in tree
    and "onLongPressStart" in tree
    and "onLongPressMove" in tree
    and "onLongPressEnd" in tree
    and "document.elementFromPoint" in tree
    and "isDragSource" in tree
    and "isDropTarget" in tree
    and "accountLongPressWiggle" in frontend_css
    and "HapticFeedback" in tree,
)
cycle_guard = "if (targetId != null && sourceNode && nodeIds(sourceNode).includes(String(targetId)))"
cycle_message = "Нельзя переместить счёт внутрь самого себя."
require(
    "drag_cycle_front_guard",
    cycle_guard in explorer
    and cycle_message in explorer
    and explorer.index(cycle_guard) < explorer.index("await moveAccount(sourceId, targetId)"),
)
require(
    "accounts_global_fab",
    "AccountCreateSheet" in app
    and "accountCreateOpen" in app
    and "<span>Счёт</span>" in app
    and ".accountsPlusButton" in frontend_css
    and "display: none !important" in frontend_css,
)
require(
    "account_create_sheet_reliable",
    "createAccount" in create_sheet
    and "await onSaved?.()" in create_sheet
    and "setError" in create_sheet,
)
require(
    "expanded_account_operations_own_only",
    "include_descendants: 'false'" in api
    and "setOptionalIdFilter(params, 'selected_account_ids', [accountId])" in api,
)
require("frontend_override_loaded_last", main.index("./ux022r3-frontend.css") > main.index("./accounts-explorer.css"))
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
    "reference_inventory_classifies_grouping_migration_journals",
    "ux022_grouping_created_account_migration_backup" in reference_inventory_sql
    and "ux022_grouping_transaction_migration_backup" in reference_inventory_sql
    and "ux022_grouping_transfer_migration_backup" in reference_inventory_sql
    and "ux022_grouping_user_default_migration_backup" in reference_inventory_sql
    and "ux022_grouping_user_settings_migration_backup" in reference_inventory_sql,
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
require("frontend_preview_does_not_name_prod", "app.moneytrackapp.xyz" not in api + app + explorer + tree + filters + recent)
require("preview_deployer_no_prod_target", "app.moneytrackapp.xyz" not in deployer)
require("runtime_uses_three_restorable_workflows", "UX022AccountLifecycle202608" not in deployer and deployer.count("export_workflow UX022") == 3)
require(
    "migration_validate_apply_same_body",
    "035_accounts_explorer_read_model_hardening.sql" in renderer
    and 'bash "$ROOT/scripts/ux022-render-migration.sh"' in migration_gate
    and 'bash "$ROOT/scripts/ux022-render-migration.sh"' in deployer,
)
require(
    "clean_checkout_script_invocation",
    'bash "$ROOT/scripts/ux022-source-gate.sh"' in deployer
    and 'bash "$ROOT/scripts/ux022-migration-gate.sh"' in deployer
    and 'bash "$ROOT/scripts/ux022-render-migration.sh"' in migration_gate,
)
require("runtime_preflight_before_mutation", "runtime_preflight=PASS" in deployer and deployer.index("runtime_preflight=PASS") < deployer.index("ux022-source-gate.sh"))
require(
    "n8n_cli_capability_preflight",
    "n8n_export_published_unsupported" in deployer
    and "n8n_publish_workflow_unsupported" in deployer
    and deployer.index("n8n_export_published_unsupported") < deployer.index("runtime_preflight=PASS"),
)
require(
    "rollback_uses_published_runtime_backup",
    '--id="$id" --published --output="/tmp/$published_name"' in deployer
    and 'import_publish "$BACKUP_DIR/transactions.before.json"' in deployer
    and 'import_publish "$BACKUP_DIR/summary.before.json"' in deployer
    and 'import_publish "$BACKUP_DIR/presets.before.json"' in deployer,
)
require(
    "draft_backup_preserved_separately",
    'draft_name="${published_name%.json}.draft.json"' in deployer
    and 'docker cp "$N8N_CONTAINER:/tmp/$draft_name" "$BACKUP_DIR/$draft_name"' in deployer,
)
require(
    "import_then_publish_then_restart",
    deployer.index('n8n import:workflow --input="/tmp/$name"') < deployer.index('n8n publish:workflow --id="$id"')
    and deployer.index('n8n publish:workflow --id="$id"') < deployer.index('docker restart "$N8N_CONTAINER"'),
)

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
