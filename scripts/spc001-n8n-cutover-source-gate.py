#!/usr/bin/env python3
"""Source-only fail-closed contract for SPC-001E2 controlled n8n cutover."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "scripts/spc001-n8n-cutover-apply.sh").read_text(encoding="utf-8")
VERIFY = (ROOT / "scripts/spc001-n8n-cutover-verify.py").read_text(encoding="utf-8")


def pos(text: str, needle: str) -> int:
    value = text.find(needle)
    return value


checks = {
    "e2_requires_explicit_apply_exact_head_and_durable_output": (
        "explicit_--apply_required" in RUNNER
        and "head_mismatch" in RUNNER
        and "durable_output_required_not_tmp" in RUNNER
    ),
    "e2_requires_e1_integrity_and_frozen_plan": (
        "E1_EVIDENCE_INTEGRITY=PASS" in RUNNER
        and "SPC001_N8N_CUTOVER_PREFLIGHT=PASS" in RUNNER
        and "E1_CUTOVER_PLAN_CONTRACT=PASS" in RUNNER
        and "cutover-plan.json" in RUNNER
    ),
    "e2_pre_mutation_runtime_drift_guard": (
        RUNNER.count("spc001-n8n-cutover-verify.py\" pre") >= 2
        and "RUNTIME_STABLE_THROUGH_BACKUP=PASS" in RUNNER
        and "NEW_WORKFLOW_IDS_ABSENT=PASS" in RUNNER
        and "CAPTURE_EXTERNAL_CALLER_GATE=PASS" in RUNNER
    ),
    "e2_uses_fresh_prod_h2_backup_before_mutation": (
        "prod-h2-backup-now.sh" in RUNNER
        and "FRESH_PROD_H2_BACKUP=PASS" in RUNNER
        and pos(RUNNER, "FRESH_PROD_H2_BACKUP=PASS") < pos(RUNNER, "MUTATED=1")
    ),
    "e2_quiesces_capture_before_processor_replacement": (
        pos(RUNNER, 'unpublish_workflow "$BOT_ID"') < pos(RUNNER, 'import_workflow "$TEXT_IMPORT"')
        and pos(RUNNER, 'unpublish_workflow "$QUICK_ID"') < pos(RUNNER, 'import_workflow "$PHOTO_IMPORT"')
        and "CAPTURE_INGRESS_QUIESCED=PASS" in RUNNER
    ),
    "e2_retires_legacy_before_new_financial_publish": (
        pos(RUNNER, 'for id in "${RETIRE_IDS[@]}"') < pos(RUNNER, 'publish_workflow "$FINANCIAL_ID"')
        and "LEGACY_FINANCIAL_UNPUBLISH=PASS" in RUNNER
    ),
    "e2_preserves_global_survivor": (
        "candidate-global-api-survivor.json" in RUNNER
        and 'publish_workflow "$SURVIVOR_ID"' in RUNNER
        and "GLOBAL_SURVIVOR_CUTOVER=PASS" in RUNNER
    ),
    "e2_updates_callees_before_callers": (
        pos(RUNNER, 'import_workflow "$TEXT_IMPORT"') < pos(RUNNER, 'import_workflow "$QUICK_IMPORT"')
        and pos(RUNNER, 'import_workflow "$PHOTO_IMPORT"') < pos(RUNNER, 'import_workflow "$BOT_IMPORT"')
    ),
    "e2_voice_processor_is_immutable": (
        "VOICE_PROCESSOR_MUTATION=NONE" in RUNNER
        and 'import_workflow "$VOICE' not in RUNNER
        and 'publish_workflow "$VOICE_ID"' not in RUNNER
    ),
    "e2_preserves_capture_publish_state": (
        "CAPTURE_PUBLISH_STATE_PRESERVED=PASS" in VERIFY
        and "capture_publish_state_drift" in VERIFY
        and "SPACE_API_REQUIRED_WORKFLOWS_PUBLISHED=PASS" in VERIFY
    ),
    "e2_post_cutover_route_and_candidate_verification": (
        "POST_CANDIDATE_CORE_PARITY=PASS" in VERIFY
        and "POST_ROUTE_OWNERSHIP=PASS" in VERIFY
        and "LEGACY_FINANCIAL_RETIRE_RUNTIME=PASS" in VERIFY
        and "UNRELATED_PUBLISHED_WORKFLOWS_PRESERVED=PASS" in VERIFY
        and "SPC001_N8N_CUTOVER_POST_RUNTIME=PASS" in VERIFY
    ),
    "e2_audits_actual_applied_tenancy": (
        "spc001-audit-workflow-tenancy.py" in RUNNER
        and "APPLIED_TENANCY_AUDIT=PASS" in RUNNER
    ),
    "e2_moneytrack_db_is_read_only": (
        "315_verify_live_post_migration_readonly.sql" in RUNNER
        and "LIVE_315_AFTER_N8N_CUTOVER=PASS" in RUNNER
        and "DB_MUTATION=NONE" in RUNNER
        and "psql -X -q -v ON_ERROR_STOP=1 -U n8n -d postgres" in RUNNER
        and "moneytrack-db" in RUNNER
    ),
    "e2_full_metadata_rollback_on_any_post_mutation_failure": (
        "ROLLBACK_TRIGGERED=YES" in RUNNER
        and "n8n-metadata.dump" in RUNNER
        and "dropdb -U n8n --if-exists n8n" in RUNNER
        and "createdb -U n8n -O n8n n8n" in RUNNER
        and "pg_restore -U n8n -d n8n --exit-on-error" in RUNNER
        and "ROLLBACK_N8N_METADATA=PASS" in RUNNER
        and "ROLLBACK_PUBLISHED_STATE_PARITY" in VERIFY
    ),
    "e2_rollback_covers_signals": (
        "trap 'on_signal HUP' HUP" in RUNNER
        and "trap 'on_signal INT' INT" in RUNNER
        and "trap 'on_signal TERM' TERM" in RUNNER
    ),
    "e2_preserves_frontend_boundary": (
        "PREVIEW_MUTATION=NONE" in RUNNER
        and "PRODUCTION_FRONTEND_MUTATION=NONE" in RUNNER
    ),
    "e2_writes_durable_terminal_evidence": (
        "cutover-metadata.txt" in RUNNER
        and "N8N_METADATA_BACKUP_SHA256" in RUNNER
        and "E1_SHA256SUMS_SHA256" in RUNNER
        and "SPC001_N8N_CUTOVER=PASS" in RUNNER
        and "SHA256SUMS" in RUNNER
    ),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_N8N_CUTOVER_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
print("N8N_MUTATION=NONE")
sys.exit(1 if failed else 0)
