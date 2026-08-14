#!/usr/bin/env python3
"""Source-only guard for SPC-001E1 read-only n8n cutover preflight."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "scripts/spc001-n8n-cutover-preflight.py").read_text(encoding="utf-8")

checks = {
    "n8n_preflight_is_export_only": (
        "export:workflow" in SRC
        and "import:workflow" not in SRC
        and "publish:workflow" not in SRC
        and "unpublish:workflow" not in SRC
    ),
    "n8n_preflight_requires_exact_head": (
        "--expected-head" in SRC and "head_mismatch" in SRC
    ),
    "n8n_preflight_requires_accepted_d3_commit": (
        "LIVE_DB_MUTATION" in SRC
        and "COMMIT_APPLIED" in SRC
        and "LIVE_POST_MIGRATION_READONLY" in SRC
        and "CLONE_SYNTHETIC_VERIFIERS" in SRC
        and "N8N_SERVICE_RESTART" in SRC
    ),
    "n8n_preflight_binds_d3_to_current_migration_program": (
        "D3_COMMIT_BUNDLE_IDENTITY=PASS" in SRC
        and "D3_ROLLBACK_BUNDLE_IDENTITY=PASS" in SRC
        and "spc001-build-db-migration.py" in SRC
    ),
    "n8n_preflight_rebuilds_live_candidates": (
        "spc001-runtime-forensic-v3.py" in SRC
        and "spc001-generate-financial-api.py" in SRC
        and "spc001-generate-control-api.py" in SRC
    ),
    "n8n_preflight_proves_legacy_route_coverage": (
        "LEGACY_FINANCIAL_ROUTE_COVERAGE=PASS" in SRC
        and "legacy_routes - financial_routes" in SRC
    ),
    "n8n_preflight_proves_published_route_conflicts_absent": (
        "--all" in SRC
        and "--published" in SRC
        and "PUBLISHED_ROUTE_CONFLICT_GATE=PASS" in SRC
    ),
    "n8n_preflight_runs_tenancy_audit": (
        "spc001-audit-workflow-tenancy.py" in SRC
        and "CANDIDATE_TENANCY_AUDIT=PASS workflows=7" in SRC
    ),
    "n8n_preflight_states_zero_mutation": all(
        marker in SRC for marker in (
            "DB_MUTATION=NONE",
            "N8N_IMPORT=NONE",
            "N8N_PUBLISH=NONE",
            "N8N_UNPUBLISH=NONE",
            "PREVIEW_MUTATION=NONE",
            "PRODUCTION_FRONTEND_MUTATION=NONE",
        )
    ),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_N8N_CUTOVER_PREFLIGHT_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
print("N8N_MUTATION=NONE")
sys.exit(1 if failed else 0)
