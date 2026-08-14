#!/usr/bin/env python3
"""SPC-001D3 source-only gate for the controlled live DB commit runner."""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

LIVE = ROOT / "scripts/spc001-db-live-commit.sh"
VERIFY = ROOT / "db/domain/SPC-001/315_verify_live_post_migration_readonly.sql"
BUILDER = ROOT / "scripts/spc001-build-db-migration.py"
BACKUP = ROOT / "scripts/prod-h2-backup-now.sh"


def text(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"SPC001_LIVE_COMMIT_SOURCE_GATE=FAIL missing={path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def require(label: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f"SPC001_LIVE_COMMIT_SOURCE_GATE=FAIL {label}")
    print(f"{label}=PASS")


def load_builder():
    spec = importlib.util.spec_from_file_location("spc001_build_db_migration", BUILDER)
    if spec is None or spec.loader is None:
        raise SystemExit("SPC001_LIVE_COMMIT_SOURCE_GATE=FAIL builder_import")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> None:
    live = text(LIVE)
    verify = text(VERIFY)
    backup = text(BACKUP)

    require(
        "live_post_migration_verifier_is_read_only",
        "begin transaction read only" in verify.lower()
        and "SPC001_LIVE_POST_MIGRATION_VERIFY=PASS" in verify
        and "SPC001_LIVE_POST_MIGRATION_VERIFY_FAILED" in verify
        and verify.lower().rstrip().endswith("rollback;"),
    )
    executable_lines = [
        line for line in verify.splitlines()
        if line.strip() and not line.lstrip().startswith("--")
    ]
    require(
        "live_post_migration_verifier_has_no_dml_or_ddl",
        not any(re.match(r"\s*(insert|update|delete|alter|create|drop|truncate)\b", line, re.I)
                for line in executable_lines),
    )

    require(
        "live_commit_requires_explicit_apply_and_exact_head",
        "explicit_--apply_required" in live
        and "--expected-head" in live
        and "head_mismatch" in live,
    )
    require(
        "live_commit_requires_durable_non_tmp_output",
        "durable_output_required_not_tmp" in live
        and "umask 077" in live
        and "chmod 700" in live,
    )
    require(
        "live_commit_requires_accepted_rehearsal_same_program",
        all(x in live for x in (
            "accepted_rollback_rehearsal=PASS",
            "REHEARSAL_ROLLBACK_SHA",
            "ROLLBACK_BUNDLE_SHA256",
            "sha256sum -c SHA256SUMS",
            "unrehearsed_migration_program",
            "commit_rollback_same_program=PASS",
        )),
    )
    require(
        "live_commit_uses_fresh_prod_h2_backup",
        all(x in live for x in (
            "prod-h2-backup-now.sh",
            "FRESH DURABLE PROD-H2 BACKUP",
            "moneytrack.dump",
            "COMPLETE",
            "MONEYTRACK_BACKUP_SHA",
            "pg_restore --list",
            "live_table_state_stable_during_backup=PASS",
        ))
        and all(x in backup for x in (
            "BACKUP_ROOT=",
            "moneytrack.dump",
            "n8n-metadata.dump",
            "n8n-data.tar.gz",
            "SHA256SUMS",
            "COMPLETE",
            "backup_result=PASS",
        )),
    )
    require(
        "live_commit_rehearses_fresh_backup_commit_on_clone",
        all(x in live for x in (
            "FRESH BACKUP COMMIT REHEARSAL ON DISPOSABLE CLONE",
            "spc001_clone_psql_file \"$COMMIT_BUNDLE\"",
            "315_verify_live_post_migration_readonly.sql",
            "090_verify_tenancy_foundation.sql",
            "091_verify_space_uniqueness_bootstrap.sql",
            "190_verify_space_lifecycle.sql",
            "290_verify_capture_projection.sql",
            "fresh_backup_commit_rehearsal=PASS",
            "clone_drop=PASS",
        )),
    )
    require(
        "live_commit_blocks_on_live_drift_before_apply",
        live.count('cmp -s "$LIVE_FP_BEFORE"') >= 3
        and "live_changed_during_backup" in live
        and "live_changed_after_backup_before_apply" in live
        and "live_changed_while_entering_quiescence" in live,
    )
    require(
        "live_commit_quiesces_n8n_and_checks_active_transactions",
        "docker stop -t 30 n8n" in live
        and "spc001_check_no_active_transactions" in live
        and "active_other_client_transactions=0" in live
        and "docker start n8n" in live
        and "spc001_restart_n8n_if_needed" in live,
    )
    require(
        "live_commit_applies_exact_commit_bundle_once_to_live",
        live.count('ux022_db_psql_file "$COMMIT_BUNDLE"') == 1
        and "APPLY EXACT ATOMIC COMMIT BUNDLE TO LIVE DB" in live
        and "atomic_live_commit_program=PASS" in live
        and "SPC001_DB_LIVE_COMMIT=PASS" in live,
    )
    require(
        "live_commit_avoids_synthetic_verifiers_on_live",
        'ux022_db_psql_file "$ROOT/db/domain/SPC-001/090_verify_tenancy_foundation.sql"' not in live
        and 'ux022_db_psql_file "$ROOT/db/domain/SPC-001/091_verify_space_uniqueness_bootstrap.sql"' not in live
        and 'ux022_db_psql_file "$ROOT/db/domain/SPC-001/190_verify_space_lifecycle.sql"' not in live
        and 'ux022_db_psql_file "$ROOT/db/domain/SPC-001/290_verify_capture_projection.sql"' not in live
        and 'ux022_db_psql_file "$ROOT/db/domain/SPC-001/315_verify_live_post_migration_readonly.sql"' in live,
    )
    require(
        "live_commit_preserves_non_db_cutover_boundary",
        all(x in live for x in (
            "N8N_IMPORT=NONE",
            "N8N_ACTIVATION=NONE",
            "PREVIEW_MUTATION=NONE",
            "PRODUCTION_FRONTEND_MUTATION=NONE",
            "NEXT=controlled n8n candidate import/activation gate",
        )),
    )

    builder = load_builder()
    commit = builder.build("commit")
    rollback = builder.build("rollback")
    require(
        "live_commit_program_matches_rehearsed_program_shape",
        commit.replace("\ncommit;\n", "\nrollback;\n") == rollback
        and "SPC001_REFERENCE_REPAIR_LEDGER=PASS" in commit
        and "SOURCE UNIT: 011_same_space_trigger_dispatch_hardening.sql" in commit,
    )

    print("SPC001_LIVE_COMMIT_SOURCE_GATE=PASS")
    print("RUNTIME_DB_EVIDENCE=NOT_CLAIMED")
    print("LIVE_DB_MUTATION=NONE")


if __name__ == "__main__":
    main()
