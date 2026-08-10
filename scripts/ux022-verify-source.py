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
read_models_sql = read("db/domain/UX-022/030_accounts_explorer_read_models.sql")
generator = read("scripts/ux022-generate-api-workflows.py")
auth = read("scripts/api-3-telegram-initdata-verifier.fragment.js")

require("collapsed_default", "useState(() => new Set())" in explorer and "accountsExplorer.expanded" not in explorer)
require("date_before_filters", explorer.index("period === 'range'") < explorer.index("<AccountsFilters"))
require("parent_own_display", "resolveOwnAmount" in explorer and "fullSubtreeTotal" in explorer)
require("tri_state_selection", "is-partial" in tree and "selectionState" in tree)
require("drag_long_press_600ms", "setTimeout(() =>" in tree and "}, 600)" in tree)
require("drag_cycle_front_guard", "ACCOUNT_HIERARCHY_CYCLE" in explorer)
require("swipe_autoclose_accounts_2000", "setTimeout(() => onActionsClose?.(id), 2000)" in tree)
require("swipe_autoclose_home_2000", "setTimeout(onActionsClose, 2000)" in recent)
require("accounts_plus", "accountsPlusButton" in explorer and "Добавить новый счёт" in explorer)
require("archive_restore_ui", "ArchivedAccountsSheet" in explorer and "restoreAccount" in explorer)
require("move_preview_ui", "previewMoveAccountOperations" in explorer and "Будет перенесено" in explorer)
require("immutable_preset_frontend", "createFilterPreset" in filters and "renameFilterPreset" in filters and "date_from" not in filters and "date_to" not in filters)
require("immutable_preset_backend", "filter_preset_create_v1" in presets_sql and "filter_preset_rename_v1" in presets_sql and "p_date_from" not in presets_sql and "p_date_to" not in presets_sql)
require("snapshot_uses_date_to", "p_as_of" in read_models_sql and "p_date_from" not in read_models_sql.split("transaction_movements as", 1)[1].split("transfer_movements as", 1)[0])
require("adjustment_is_expense", "transaction_type in ('expense','adjustment')" in read_models_sql)
require("internal_transfer_suppression", "((sa_from.id is not null) <> (sa_to.id is not null))" in read_models_sql)
require("history_move_atomic_boundary", "account_move_operations_v1" in lifecycle_sql and "update moneytrack.transactions" in lifecycle_sql and "update moneytrack.transfers" in lifecycle_sql)
require("history_move_no_fx", "account_move_operations_v1" in lifecycle_sql and "ACCOUNT_CURRENCY_INCOMPATIBLE" in lifecycle_sql)
require("delete_no_finance_cascade", "ACCOUNT_HAS_OPERATIONS" in lifecycle_sql and "ACCOUNT_HAS_REFERENCES" in lifecycle_sql and "cascade" not in lifecycle_sql.lower())
require("archive_zero_balance", "ACCOUNT_BALANCE_NOT_ZERO" in lifecycle_sql and "account_archive_v1" in lifecycle_sql)
require("canonical_auth_contract", "api3b-v1" in auth and "api-3-telegram-initdata-verifier.fragment.js" in generator)
require("frontend_preview_does_not_name_prod", "app.moneytrackapp.xyz" not in api + explorer + tree + filters + recent)

with tempfile.TemporaryDirectory(prefix="ux022-source-") as tmp:
    out = Path(tmp)
    subprocess.run([sys.executable, str(ROOT / "scripts/ux022-generate-api-workflows.py"), "--out-dir", str(out)], check=True)
    candidates = sorted(out.glob("*.candidate.json"))
    require("workflow_candidates_generated", len(candidates) == 4)
    all_queries: list[str] = []
    for candidate in candidates:
        workflow = json.loads(candidate.read_text(encoding="utf-8"))
        for node in workflow.get("nodes", []):
            if node.get("type") == "n8n-nodes-base.postgres":
                query = node.get("parameters", {}).get("query", "")
                all_queries.append(query)
                require(f"thin_adapter_{candidate.stem}_{node['name']}", query.strip().lower().startswith("select * from moneytrack."))
    joined = "\n".join(all_queries).lower()
    require("thin_adapter_no_dml", not any(token in joined for token in ("insert into ", "update moneytrack.", "delete from ")))

print("SOURCE_GATE=PASS")
