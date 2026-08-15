#!/usr/bin/env python3
"""Source-only gate for the SPC-001F4 financial transport correction."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/spc001-generate-financial-api.py"
RUNNER = ROOT / "scripts/spc001-f4-financial-transport-apply.sh"
VERIFY = ROOT / "scripts/spc001-f4-financial-transport-verify.py"


def run_formatter(js: str, row: dict) -> dict:
    script = f"""
const $input = {{ first: () => ({{ json: {json.dumps(row)} }}) }};
const execute = () => {{
{js}
}};
const result = execute();
if (!Array.isArray(result) || !result[0] || !result[0].json) process.exit(91);
process.stdout.write(JSON.stringify(result[0].json));
"""
    proc = subprocess.run(
        ["node", "-e", script],
        check=True,
        text=True,
        capture_output=True,
    )
    return json.loads(proc.stdout)


with tempfile.TemporaryDirectory(prefix="spc001-f4-transport-") as tmp:
    candidate = Path(tmp) / "financial.json"
    subprocess.run(
        [sys.executable, str(GENERATOR), "--output", str(candidate)],
        check=True,
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
    )
    wf = json.loads(candidate.read_text(encoding="utf-8"))

format_nodes = [
    node for node in wf.get("nodes", [])
    if node.get("type") == "n8n-nodes-base.code"
    and str(node.get("name", "")).endswith(" Format")
]
formatter_sources = {
    str((node.get("parameters") or {}).get("jsCode") or "")
    for node in format_nodes
}

checks: dict[str, bool] = {
    "financial_candidate_identity_and_route_shape": (
        wf.get("id") == "SPC001FinancialApi202608"
        and len(format_nodes) == 30
        and len(formatter_sources) == 1
    ),
}

formatter = next(iter(formatter_sources), "")
checks["financial_formatter_walks_nested_error_item"] = all(x in formatter for x in (
    "collectStrings",
    "Object.values(value)",
    "extractDomainCode(row)",
    "(?:_[A-Z0-9]+)+",
))
checks["financial_formatter_prefers_space_access_loss"] = all(x in formatter for x in (
    '"SPACE_NOT_FOUND_OR_NOT_MEMBER"',
    '"SPACE_CONTEXT_NOT_FOUND"',
    "joined.includes(code)",
))
checks["financial_formatter_maps_access_loss_to_403"] = (
    "forbidden.has(code)?403:400" in formatter
)

fixtures = {
    "nested_membership": {
        "error": {
            "message": "Node operation failed",
            "details": {"cause": "ERROR: SPACE_NOT_FOUND_OR_NOT_MEMBER"},
        }
    },
    "array_nested_membership": {
        "error": {
            "message": "P0002",
            "context": ["query", {"description": "SPACE_NOT_FOUND_OR_NOT_MEMBER"}],
        }
    },
    "nested_context_loss": {
        "error": {"description": {"reason": "SPACE_CONTEXT_NOT_FOUND"}}
    },
    "business_error": {
        "error": {"cause": {"message": "ACCOUNT_BALANCE_NOT_ZERO"}}
    },
    "sqlstate_only": {
        "error": {"message": "P0002"}
    },
}

try:
    nested = run_formatter(formatter, fixtures["nested_membership"])
    array_nested = run_formatter(formatter, fixtures["array_nested_membership"])
    context_loss = run_formatter(formatter, fixtures["nested_context_loss"])
    business = run_formatter(formatter, fixtures["business_error"])
    sqlstate = run_formatter(formatter, fixtures["sqlstate_only"])
    checks["financial_formatter_runtime_nested_membership_403"] = (
        nested == {"ok": False, "http_status": 403, "error": {"code": "SPACE_NOT_FOUND_OR_NOT_MEMBER"}}
        and array_nested == nested
    )
    checks["financial_formatter_runtime_context_loss_403"] = (
        context_loss == {"ok": False, "http_status": 403, "error": {"code": "SPACE_CONTEXT_NOT_FOUND"}}
    )
    checks["financial_formatter_runtime_business_error_preserved"] = (
        business == {"ok": False, "http_status": 400, "error": {"code": "ACCOUNT_BALANCE_NOT_ZERO"}}
    )
    checks["financial_formatter_does_not_promote_sqlstate"] = (
        sqlstate == {"ok": False, "http_status": 400, "error": {"code": "DOMAIN_ERROR"}}
    )
except Exception:
    checks["financial_formatter_runtime_nested_membership_403"] = False
    checks["financial_formatter_runtime_context_loss_403"] = False
    checks["financial_formatter_runtime_business_error_preserved"] = False
    checks["financial_formatter_does_not_promote_sqlstate"] = False

runner = RUNNER.read_text(encoding="utf-8") if RUNNER.exists() else ""
verify = VERIFY.read_text(encoding="utf-8") if VERIFY.exists() else ""
checks["f4_transport_apply_requires_exact_head_f4_evidence_and_safe_delta"] = all(x in runner for x in (
    "explicit_--apply_required",
    "head_mismatch",
    "SPC001_F4_PREVIEW=PASS",
    "F4_PREVIEW_TO_TRANSPORT_SAFE_DELTA=PASS",
    "git merge-base --is-ancestor",
))
checks["f4_transport_apply_mutates_only_financial_workflow"] = all(x in runner for x in (
    'FINANCIAL_ID="SPC001FinancialApi202608"',
    'import_workflow "$CANDIDATE_IMPORT" "$FINANCIAL_ID"',
    'publish_workflow "$FINANCIAL_ID"',
    "N8N_WORKFLOW_MUTATION=FINANCIAL_TRANSPORT_ONLY",
    "CONTROL_WORKFLOW_MUTATION=NONE",
    "CAPTURE_WORKFLOW_MUTATION=NONE",
)) and "unpublish_workflow" not in runner
checks["f4_transport_apply_has_fresh_metadata_backup_and_full_rollback"] = all(x in runner for x in (
    "prod-h2-backup-now.sh",
    "n8n-metadata.dump",
    "ROLLBACK_TRIGGERED=YES",
    "dropdb -U n8n --if-exists n8n",
    "createdb -U n8n -O n8n n8n",
    "pg_restore -U n8n -d n8n --exit-on-error",
    "ROLLBACK_N8N_METADATA=PASS",
))
checks["f4_transport_apply_proves_moneytrack_db_readonly"] = all(x in runner for x in (
    "315_verify_live_post_migration_readonly.sql",
    "LIVE_315_BEFORE_TRANSPORT=PASS",
    "LIVE_315_AFTER_TRANSPORT=PASS",
    "LIVE_315_UNCHANGED=PASS",
    "DB_MUTATION=NONE",
))
checks["f4_transport_apply_preserves_frontend_boundaries"] = all(x in runner for x in (
    "PREVIEW_MUTATION=NONE",
    "PRODUCTION_FRONTEND_MUTATION=NONE",
))
checks["f4_transport_runtime_verify_enforces_only_financial_core_change"] = all(x in verify for x in (
    "FINANCIAL_CURRENT_CORE_PARITY=PASS",
    "UNRELATED_PUBLISHED_WORKFLOWS_UNCHANGED=PASS",
    "PUBLISHED_WORKFLOW_ID_SET_PRESERVED=PASS",
    "FINANCIAL_ROUTE_OWNERSHIP=PASS",
    "ROLLBACK_PUBLISHED_STATE_PARITY=PASS",
))

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_F4_FINANCIAL_TRANSPORT_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
print("N8N_MUTATION=NONE")
print("PREVIEW_MUTATION=NONE")
print("PRODUCTION_FRONTEND_MUTATION=NONE")
raise SystemExit(1 if failed else 0)
