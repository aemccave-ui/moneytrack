#!/usr/bin/env python3
"""Source-only gate for SPC-001 filter-preset reference migration coverage."""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPC = ROOT / "db" / "domain" / "SPC-001"
BUILDER = ROOT / "scripts" / "spc001-build-db-migration.py"
REHEARSAL = ROOT / "scripts" / "spc001-db-rollback-rehearsal.sh"

FILES = {
    "baseline": SPC / "302_migration_filter_preset_reference_baseline.sql",
    "repair": SPC / "311_migration_filter_preset_reference_repair.sql",
    "diagnostic": SPC / "314_filter_preset_reference_diagnostic.sql",
    "reconcile": SPC / "316_migration_filter_preset_reference_reconciliation.sql",
}

TX = re.compile(r"^\s*(?:begin|commit|rollback)\s*;\s*$", re.I)


def read(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"SPC001_FILTER_PRESET_MIGRATION_SOURCE_GATE=FAIL missing={path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def require(label: str, ok: bool) -> None:
    if not ok:
        raise SystemExit(f"SPC001_FILTER_PRESET_MIGRATION_SOURCE_GATE=FAIL {label}")
    print(f"{label}=PASS")


def no_tx(text: str) -> bool:
    return not any(TX.match(line) for line in text.splitlines())


def load_builder():
    spec = importlib.util.spec_from_file_location("spc001_build_db_migration", BUILDER)
    if spec is None or spec.loader is None:
        raise SystemExit("SPC001_FILTER_PRESET_MIGRATION_SOURCE_GATE=FAIL builder_import")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    baseline = read(FILES["baseline"])
    repair = read(FILES["repair"])
    diagnostic = read(FILES["diagnostic"])
    reconcile = read(FILES["reconcile"])
    rehearsal = read(REHEARSAL)

    require(
        "filter_preset_reference_baseline_fragment",
        no_tx(baseline)
        and all(x in baseline for x in (
            "spc001_filter_reference_baseline",
            "with ordinality",
            "'account'",
            "'income_category'",
            "'expense_category'",
            "spc001_filter_preset_business_baseline",
            "SPC001_FILTER_PRESET_BASELINE=PASS",
        )),
    )

    require(
        "filter_preset_reference_repair_ledger_backed",
        no_tx(repair)
        and all(x in repair for x in (
            "spc001_filter_reference_repairs",
            "src.user_id=0",
            "src.space_id is null",
            "target.space_id=p.space_id",
            "target.code is not distinct from src.code",
            "set income_category_ids=",
            "expense_category_ids=(",
            "order by x.ord",
            "SPC001_FILTER_PRESET_REPAIR_COVERAGE_FAILED",
            "SPC001_FILTER_PRESET_REFERENCE_REPAIR=PASS",
        ))
        and "set account_ids=" not in repair.lower(),
    )

    require(
        "filter_preset_reference_repair_preserves_legacy_contract",
        "kind text not null check (kind in ('income_category','expense_category'))" in repair
        and "set account_ids=" not in repair.lower()
        and "old_target_id <> new_target_id" in repair,
    )

    repair_updates = re.findall(
        r"\bupdate\s+moneytrack\.filter_presets\s+p\b",
        repair,
        flags=re.I,
    )
    atomic_set = re.search(
        r"\bupdate\s+moneytrack\.filter_presets\s+p\s+"
        r"set\s+income_category_ids\s*=.*?,\s*"
        r"expense_category_ids\s*=.*?\s+where\s+exists\s*\(",
        repair,
        flags=re.I | re.S,
    )
    require(
        "filter_preset_reference_repair_single_row_atomic_update",
        len(repair_updates) == 1 and atomic_set is not None,
    )

    require(
        "filter_preset_reference_reconciliation_fail_closed",
        no_tx(reconcile)
        and all(x in reconcile for x in (
            "filter_preset_business_changed",
            "filter_reference_position_changed",
            "filter_unledgered_reference_change",
            "filter_repair_ledger_mismatch",
            "filter_account_cross_space",
            "filter_category_cross_space",
            "SPC001_FILTER_PRESET_REFERENCE_RECONCILIATION_FAILED",
            "SPC001_FILTER_PRESET_REFERENCE_LEDGER=PASS",
            "SPC001_FILTER_PRESET_REFERENCES=PASS",
        )),
    )

    require(
        "filter_preset_live_diagnostic_matches_repair_identity",
        "begin transaction read only" in diagnostic.lower()
        and "candidate_zero=" in diagnostic
        and "candidate_many=" in diagnostic
        and "target.code is not distinct from c.code" in diagnostic
        and "SPC001_FILTER_PRESET_REFERENCE_DIAGNOSTIC=PASS" in diagnostic,
    )

    builder = load_builder()
    require(
        "filter_preset_builder_fragments_selected",
        builder.FILTER_BASELINE == "302_migration_filter_preset_reference_baseline.sql"
        and builder.FILTER_REPAIR == "311_migration_filter_preset_reference_repair.sql"
        and builder.FILTER_RECONCILE == "316_migration_filter_preset_reference_reconciliation.sql",
    )

    commit = builder.build("commit")
    rollback = builder.build("rollback")
    require(
        "filter_preset_builder_atomic_program_same_commit_rollback",
        commit.replace("\ncommit;\n", "\nrollback;\n") == rollback,
    )

    baseline_marker = "PRE-MUTATION FILTER PRESET REFERENCE BASELINE"
    main_reconcile_marker = "-- ===== PRE-COMMIT RECONCILIATION ====="
    repair_marker = "CONTROLLED FILTER PRESET REFERENCE REPAIR"
    filter_reconcile_marker = "PRE-COMMIT FILTER PRESET RECONCILIATION"
    require(
        "filter_preset_builder_order",
        baseline_marker in commit
        and main_reconcile_marker in commit
        and repair_marker in commit
        and filter_reconcile_marker in commit
        and commit.index(baseline_marker) < commit.index("SOURCE UNIT: 010_tenancy_foundation.sql")
        and commit.index(main_reconcile_marker) < commit.index(repair_marker)
        and commit.index(repair_marker) < commit.index(filter_reconcile_marker)
        and commit.index(filter_reconcile_marker) < commit.rindex("\ncommit;"),
    )

    filter_markers = (
        "SPC001_FILTER_PRESET_BASELINE=PASS",
        "SPC001_FILTER_PRESET_REFERENCE_REPAIR=PASS",
        "SPC001_FILTER_PRESET_REFERENCE_LEDGER=PASS",
        "SPC001_FILTER_PRESET_REFERENCES=PASS",
    )
    require(
        "filter_preset_bundle_runtime_markers",
        all(x in commit for x in filter_markers),
    )
    require(
        "filter_preset_rollback_rehearsal_requires_runtime_markers",
        all(x in rehearsal for x in filter_markers)
        and "CONTROLLED FILTER PRESET REFERENCE REPAIR" in rehearsal,
    )

    print("SPC001_FILTER_PRESET_MIGRATION_SOURCE_GATE=PASS")
    print("RUNTIME_DB_EVIDENCE=NOT_CLAIMED")
    print("DB_MUTATION=NONE")


if __name__ == "__main__":
    main()
