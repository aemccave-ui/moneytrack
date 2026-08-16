#!/usr/bin/env python3
"""SPC-001D source-only gate for controlled DB migration construction."""
from __future__ import annotations

import importlib.util
import re
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REQUIRED = (
    ".gitignore",
    "db/domain/SPC-001/011_same_space_trigger_dispatch_hardening.sql",
    "db/domain/SPC-001/300_migration_baseline.sql",
    "db/domain/SPC-001/301_migration_baseline_reference_repair.sql",
    "db/domain/SPC-001/305_migration_preflight.sql",
    "db/domain/SPC-001/306_migration_cross_user_diagnostic.sql",
    "db/domain/SPC-001/307_migration_reference_provenance_diagnostic.sql",
    "db/domain/SPC-001/308_migration_reference_repairability_preflight.sql",
    "db/domain/SPC-001/309_migration_legacy_reference_repair.sql",
    "db/domain/SPC-001/310_migration_reconciliation_guard.sql",
    "db/domain/SPC-001/312_migration_reconciliation_guard_reference_repair.sql",
    "db/domain/SPC-001/313_runtime_table_fingerprint.sql",
    "scripts/spc001-build-db-migration.py",
    "scripts/spc001-db-migration-forensic.sh",
    "scripts/spc001-db-rollback-rehearsal.sh",
)


def read(path: str) -> str:
    p = ROOT / path
    if not p.is_file():
        raise SystemExit(f"SPC001_MIGRATION_SOURCE_GATE=FAIL missing={path}")
    return p.read_text(encoding="utf-8")


def require(label: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f"SPC001_MIGRATION_SOURCE_GATE=FAIL {label}")
    print(f"{label}=PASS")


def load_builder():
    path = ROOT / "scripts/spc001-build-db-migration.py"
    spec = importlib.util.spec_from_file_location("spc001_build_db_migration", path)
    if spec is None or spec.loader is None:
        raise SystemExit("SPC001_MIGRATION_SOURCE_GATE=FAIL builder_import")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tx_lines(text: str) -> list[str]:
    return [
        line.strip().lower()
        for line in text.splitlines()
        if re.fullmatch(r"\s*(?:begin|commit|rollback)\s*;\s*", line, re.I)
    ]


def main() -> None:
    for path in REQUIRED:
        read(path)
    print(f"migration_required_source_files=PASS count={len(REQUIRED)}")

    gitignore = read(".gitignore")
    trigger_hardening = read("db/domain/SPC-001/011_same_space_trigger_dispatch_hardening.sql")
    baseline_v2 = read("db/domain/SPC-001/301_migration_baseline_reference_repair.sql")
    preflight = read("db/domain/SPC-001/305_migration_preflight.sql")
    diagnostic = read("db/domain/SPC-001/306_migration_cross_user_diagnostic.sql")
    provenance = read("db/domain/SPC-001/307_migration_reference_provenance_diagnostic.sql")
    repairability = read("db/domain/SPC-001/308_migration_reference_repairability_preflight.sql")
    repair = read("db/domain/SPC-001/309_migration_legacy_reference_repair.sql")
    reconcile_v2 = read("db/domain/SPC-001/312_migration_reconciliation_guard_reference_repair.sql")
    fingerprint = read("db/domain/SPC-001/313_runtime_table_fingerprint.sql")
    forensic = read("scripts/spc001-db-migration-forensic.sh")
    rehearsal = read("scripts/spc001-db-rollback-rehearsal.sh")

    require(
        "migration_python_cache_ignored",
        "__pycache__/" in gitignore and "*.py[cod]" in gitignore,
    )
    require(
        "migration_trigger_dispatch_hardening_dynamic_record_safe",
        all(x in trigger_hardening for x in (
            "create or replace function moneytrack.spc001_assert_same_space_row_v1()",
            "tg_table_name = 'accounts'",
            "tg_table_name = 'transactions'",
            "tg_table_name = 'transfers'",
            "tg_table_name = 'receipts'",
            "tg_table_name = 'category_catalog'",
            "tg_table_name = 'product_catalog'",
            "tg_table_name = 'budget_rules'",
            "tg_table_name = 'space_default_accounts'",
            "tg_table_name = 'space_financial_settings'",
            "tg_table_name = 'receipt_items'",
            "SPC001_UNSUPPORTED_SAME_SPACE_TRIGGER_TABLE",
        ))
        and re.search(r"tg_table_name\s*=\s*'[^']+'\s+and\s+new\.", trigger_hardening, re.I) is None,
    )
    require(
        "migration_baseline_reference_repair_guarded",
        all(x in baseline_v2 for x in (
            "spc001_migration_baseline",
            "spc001_reference_baseline",
            "transaction_account",
            "receipt_item_category",
            "product_category",
            "budget_category",
            "amount_original",
            "amount_base",
            "from_amount",
            "to_amount",
            "row_digest",
        )),
    )
    require(
        "migration_preflight_is_read_only_fail_closed",
        all(x in preflight for x in (
            "begin transaction read only",
            "SPC001_DB_PREFLIGHT_FAILED",
            "multiple_active_personal_space_owners",
            "personal_space_foreign_members",
            "transaction_account_cross_user",
            "receipt_item_product_cross_user",
            "SPC001_DB_PREFLIGHT=PASS",
            "rollback;",
        )),
    )
    require(
        "migration_cross_user_diagnostic_read_only",
        all(x in diagnostic for x in (
            "begin transaction read only",
            "SPC001_CROSS_USER_DIAGNOSTIC=BEGIN",
            "candidate_count",
            "SPC001_CROSS_USER_DETERMINISTIC_REMAP=",
            "SPC001_CROSS_USER_DIAGNOSTIC=END",
            "rollback;",
        )),
    )
    require(
        "migration_reference_provenance_read_only",
        all(x in provenance for x in (
            "begin transaction read only",
            "SPC001_REFERENCE_PROVENANCE_DIAGNOSTIC=BEGIN",
            "TX_PROVENANCE|",
            "ACCOUNT_TARGET_PROVENANCE|",
            "CATEGORY_TARGET_PROVENANCE|",
            "CROSS_USER_TX_RECEIPT_OWNER_MISMATCH=",
            "SPC001_REFERENCE_PROVENANCE_DIAGNOSTIC=END",
            "rollback;",
        )),
    )
    require(
        "migration_reference_repairability_read_only_fail_closed",
        all(x in repairability for x in (
            "begin transaction read only",
            "SPC001_REFERENCE_REPAIRABILITY_FAILED",
            "repair_account_path_invalid",
            "repair_category_path_invalid",
            "repair_account_candidate_incompatible",
            "repair_category_candidate_incompatible",
            "SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS",
            "rollback;",
        )),
    )
    require(
        "migration_reference_repair_is_ledger_backed_fragment",
        tx_lines(repair) == []
        and all(x in repair for x in (
            "spc001_legacy_reference_clones",
            "spc001_legacy_reference_repairs",
            "spc001_account_reference_map",
            "spc001_category_reference_map",
            "SPC001_LEGACY_REFERENCE_REPAIR=PASS",
            "transaction_account",
            "receipt_item_category",
            "product_category",
            "budget_category",
        )),
    )
    require(
        "migration_reconciliation_reference_repair_guarded",
        all(x in reconcile_v2 for x in (
            "legacy_business_data_changed",
            "account_clone_count_mismatch",
            "category_clone_count_mismatch",
            "unledgered_reference_change",
            "repair_ledger_mismatch",
            "SPC001_REFERENCE_REPAIR_LEDGER=PASS",
            "SPC001_LEGACY_MONETARY_TOTALS=PASS",
            "SPC001_PERSONAL_SPACE_MIGRATION=PASS",
            "SPC001_SAME_SPACE_REFERENCES=PASS",
            "SPC001_CAPTURE_PROVENANCE_MIGRATION=PASS",
            "SPC001_ATOMIC_RECONCILIATION_FAILED",
        )),
    )
    require(
        "migration_runtime_table_fingerprint_is_read_only",
        all(x in fingerprint for x in (
            "begin transaction read only",
            "pg_tables",
            "to_jsonb(t)",
            "TABLE_FINGERPRINT|table=",
            "SPC001_TABLE_FINGERPRINT=BEGIN",
            "SPC001_TABLE_FINGERPRINT=END",
            "rollback;",
        )),
    )
    require(
        "migration_forensic_is_read_only_repairability_gate",
        "306_migration_cross_user_diagnostic.sql" in forensic
        and "307_migration_reference_provenance_diagnostic.sql" in forensic
        and "308_migration_reference_repairability_preflight.sql" in forensic
        and "305_migration_preflight.sql" in forensic
        and "db-reference-repairability.txt" in forensic
        and "SPC001_DB_MIGRATION_FORENSIC=PASS repairable_legacy_reference_plan" in forensic
        and "ux022_db_psql_file \"$COMMIT_BUNDLE\"" not in forensic
        and "ux022_db_psql_file \"$ROLLBACK_BUNDLE\"" not in forensic
        and "DB_MUTATION=NONE" in forensic,
    )
    require(
        "migration_rollback_rehearsal_isolated_from_live_db",
        all(x in rehearsal for x in (
            "REHEARSAL_TARGET=DISPOSABLE_DATABASE_CLONE",
            "COMMIT_FORBIDDEN=YES",
            "unsupported_db_runtime_mode",
            "spc001_live_backup",
            "exec pg_restore --list",
            "createdb",
            "dropdb",
            "spc001_clone_psql_file \"$ROLLBACK_BUNDLE\"",
            "313_runtime_table_fingerprint.sql",
            "clone_schema_after_rollback=PASS",
            "live_table_state_unchanged=PASS",
            "LIVE_DB_MUTATION=NONE",
            "SPC001_DB_ROLLBACK_REHEARSAL=PASS",
        ))
        and "ux022_db_psql_file \"$ROLLBACK_BUNDLE\"" not in rehearsal
        and "--final commit" not in rehearsal,
    )
    require(
        "migration_rollback_rehearsal_requires_backup_evidence",
        all(x in rehearsal for x in (
            "--format=custom",
            "BACKUP_SHA256",
            "live-pre-rehearsal.dump",
            "live-pre-rehearsal.list",
            "SHA256SUMS",
            "clone_restore=PASS",
            "rollback_bundle_exact_shape=PASS",
        )),
    )

    builder = load_builder()
    require("migration_unit_count", len(builder.MUTATION_UNITS) == 27)
    require(
        "migration_trigger_dispatch_hardening_ordered_after_foundation",
        builder.MUTATION_UNITS[:3] == [
            "010_tenancy_foundation.sql",
            "011_same_space_trigger_dispatch_hardening.sql",
            "012_tenancy_uniqueness_hardening.sql",
        ],
    )
    require("migration_builder_uses_reference_repair_v2", all((
        builder.BASELINE == "301_migration_baseline_reference_repair.sql",
        builder.REPAIR == "309_migration_legacy_reference_repair.sql",
        builder.RECONCILE == "312_migration_reconciliation_guard_reference_repair.sql",
    )))
    commit = builder.build("commit")
    rollback = builder.build("rollback")
    require("migration_atomic_commit_shape", tx_lines(commit) == ["begin;", "commit;"])
    require("migration_atomic_rollback_shape", tx_lines(rollback) == ["begin;", "rollback;"])
    require(
        "migration_commit_rollback_same_program",
        commit.replace("\ncommit;\n", "\nrollback;\n") == rollback,
    )
    require(
        "migration_advisory_lock",
        "pg_advisory_xact_lock" in commit and "SPC-001:controlled-migration" in commit,
    )
    require(
        "migration_reference_repair_injected_before_foundation_reconcile",
        "CONTROLLED LEGACY REFERENCE REPAIR" in commit
        and commit.index("CONTROLLED LEGACY REFERENCE REPAIR")
            < commit.index("-- 6. Reconciliation MUST pass before this transaction can commit."),
    )
    require(
        "migration_trigger_dispatch_hardening_embedded_after_foundation",
        "SOURCE UNIT: 011_same_space_trigger_dispatch_hardening.sql" in commit
        and commit.index("SOURCE UNIT: 010_tenancy_foundation.sql")
            < commit.index("SOURCE UNIT: 011_same_space_trigger_dispatch_hardening.sql")
            < commit.index("SOURCE UNIT: 012_tenancy_uniqueness_hardening.sql"),
    )
    require(
        "migration_baseline_and_reconcile_embedded",
        "PRE-MUTATION BASELINE" in commit
        and "PRE-COMMIT RECONCILIATION" in commit
        and "SPC001_REFERENCE_REPAIR_LEDGER=PASS" in commit,
    )

    with tempfile.TemporaryDirectory(prefix="spc001-migration-gate-") as d:
        out = Path(d) / "candidate.sql"
        out.write_text(commit, encoding="utf-8")
        require("migration_candidate_nonempty", out.stat().st_size > 1000)

    print("SPC001_MIGRATION_SOURCE_GATE=PASS")
    print("RUNTIME_DB_EVIDENCE=NOT_CLAIMED")
    print("DB_MUTATION=NONE")


if __name__ == "__main__":
    main()
