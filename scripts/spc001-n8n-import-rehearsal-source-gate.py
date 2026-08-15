#!/usr/bin/env python3
"""Source-only gate for SPC-001E2R disposable n8n metadata rehearsal."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "scripts/spc001-n8n-import-rehearsal.sh").read_text(encoding="utf-8")

checks = {
    "e2r_requires_exact_head_and_durable_output": all(x in SRC for x in (
        "--expected-head", "durable_output_required", "git status --porcelain", "git rev-parse HEAD"
    )),
    "e2r_requires_e1_and_backup_hash_integrity": (
        "sha256sum -c SHA256SUMS" in SRC
        and "SPC001_N8N_CUTOVER_PREFLIGHT=PASS" in SRC
        and "n8n-metadata.dump" in SRC
    ),
    "e2r_uses_disposable_n8n_database": (
        "spc001_n8n_rehearsal_" in SRC
        and "createdb -U n8n -O n8n" in SRC
        and "dropdb -U n8n --if-exists" in SRC
    ),
    "e2r_overrides_only_cli_database_target": (
        "DB_POSTGRESDB_DATABASE=\"$CLONE_DB\"" in SRC
        and "N8N_CLONE_DB_ENV_OVERRIDE_CONTRACT=PASS" in SRC
    ),
    "e2r_captures_import_and_publish_diagnostics": all(x in SRC for x in (
        "CLONE_IMPORT=FAIL", "CLONE_IMPORT=PASS", "CLONE_PUBLISH=FAIL", "CLONE_PUBLISH=PASS"
    )),
    "e2r_rehearses_full_cutover_order": (
        SRC.index('unpublish_clone "$BOT_ID"')
        < SRC.index('for id in "${RETIRE_IDS[@]}"; do unpublish_clone "$id"; done')
        < SRC.index('import_clone "$SURVIVOR_IMPORT"')
        < SRC.index('import_clone "$FINANCIAL_IMPORT"')
        < SRC.index('import_clone "$CONTROL_IMPORT"')
        < SRC.index('import_clone "$TEXT_IMPORT"')
        < SRC.index('import_clone "$QUICK_IMPORT"')
        < SRC.index('import_clone "$BOT_IMPORT"')
    ),
    "e2r_voice_is_immutable": (
        "CLONE_VOICE_PROCESSOR_MUTATION=NONE" in SRC
        and 'import_clone "$VOICE' not in SRC
        and 'publish_clone "$VOICE' not in SRC
        and 'unpublish_clone "$VOICE' not in SRC
    ),
    "e2r_runs_existing_post_verifier": (
        "spc001-n8n-cutover-verify.py\" post" in SRC
        and "CLONE_METADATA_CUTOVER=PASS" in SRC
    ),
    "e2r_states_production_zero_mutation": (
        "PRODUCTION_N8N_METADATA_MUTATION=NONE" in SRC
        and "MONEYTRACK_DB_MUTATION=NONE" in SRC
    ),
    "e2r_cleanup_is_fail_closed": (
        "trap cleanup EXIT" in SRC
        and "CLONE_DROPPED=YES" in SRC
        and "SPC001_N8N_IMPORT_REHEARSAL=FAIL" in SRC
    ),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok
print(f"SPC001_N8N_IMPORT_REHEARSAL_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("PRODUCTION_N8N_METADATA_MUTATION=NONE")
print("MONEYTRACK_DB_MUTATION=NONE")
sys.exit(1 if failed else 0)
