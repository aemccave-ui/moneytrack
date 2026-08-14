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
    "db/domain/SPC-001/300_migration_baseline.sql",
    "db/domain/SPC-001/305_migration_preflight.sql",
    "db/domain/SPC-001/306_migration_cross_user_diagnostic.sql",
    "db/domain/SPC-001/310_migration_reconciliation_guard.sql",
    "scripts/spc001-build-db-migration.py",
    "scripts/spc001-db-migration-forensic.sh",
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
    baseline = read("db/domain/SPC-001/300_migration_baseline.sql")
    preflight = read("db/domain/SPC-001/305_migration_preflight.sql")
    diagnostic = read("db/domain/SPC-001/306_migration_cross_user_diagnostic.sql")
    reconcile = read("db/domain/SPC-001/310_migration_reconciliation_guard.sql")
    forensic = read("scripts/spc001-db-migration-forensic.sh")

    require(
        "migration_python_cache_ignored",
        "__pycache__/" in gitignore and "*.py[cod]" in gitignore,
    )
    require(
        "migration_baseline_preserves_legacy_business_rows",
        all(x in baseline for x in (
            "spc001_migration_baseline",
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
            "transaction_account",
            "receipt_item_category",
            "product_category",
            "budget_category",
            "candidate_count",
            "SPC001_CROSS_USER_DETERMINISTIC_REMAP=",
            "SPC001_CROSS_USER_DIAGNOSTIC=END",
            "rollback;",
        )),
    )
    require(
        "migration_reconciliation_before_commit",
        all(x in reconcile for x in (
            "legacy_business_data_changed",
            "SPC001_LEGACY_MONETARY_TOTALS=PASS",
            "SPC001_PERSONAL_SPACE_MIGRATION=PASS",
            "SPC001_CAPTURE_PROVENANCE_MIGRATION=PASS",
            "SPC001_ATOMIC_RECONCILIATION_FAILED",
        )),
    )
    require(
        "migration_forensic_has_no_apply",
        "306_migration_cross_user_diagnostic.sql" in forensic
        and "305_migration_preflight.sql" in forensic
        and "ux022_db_psql_file \"$COMMIT_BUNDLE\"" not in forensic
        and "DB_MUTATION=NONE" in forensic
        and "SPC001_DB_MIGRATION_FORENSIC=PASS" in forensic,
    )
    require(
        "migration_forensic_preserves_failure_evidence",
        all(x in forensic for x in (
            "db-cross-user-diagnostic.txt",
            "db-preflight.txt",
            "SHA256SUMS",
            "SPC001_DB_MIGRATION_FORENSIC=FAIL live_db_preflight",
        )),
    )

    builder = load_builder()
    require("migration_unit_count", len(builder.MUTATION_UNITS) == 26)
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
        "migration_baseline_and_reconcile_embedded",
        "PRE-MUTATION BASELINE" in commit and "PRE-COMMIT RECONCILIATION" in commit,
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
