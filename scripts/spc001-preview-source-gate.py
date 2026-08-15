#!/usr/bin/env python3
"""Source-only gate for SPC-001F preview-only deployment and F2R1 correction."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "scripts/spc001-preview-apply.sh").read_text(encoding="utf-8")
CORRECTIVE = (ROOT / "scripts/spc001-f2r1-preview-apply.sh").read_text(encoding="utf-8")
MAIN = (ROOT / "miniapp/src/main.jsx").read_text(encoding="utf-8")
SPACE_GATE = (ROOT / "miniapp/src/SpaceGate.jsx").read_text(encoding="utf-8")
SPACE_CSS = (ROOT / "miniapp/src/spc001-space.css").read_text(encoding="utf-8")
API = (ROOT / "miniapp/src/api.js").read_text(encoding="utf-8")

checks = {
    "preview_requires_explicit_apply_exact_head_and_durable_output": all(x in RUNNER for x in (
        "explicit_--apply_required",
        "head mismatch expected=",
        "durable_output_required",
        "git status --porcelain",
    )),
    "preview_requires_accepted_e2_integrity": all(x in RUNNER for x in (
        "cutover-metadata.txt",
        "sha256sum -c SHA256SUMS",
        "N8N_MUTATION=CUTOVER_APPLIED",
        "N8N_ROLLBACK=NOT_REQUIRED",
        "LIVE_315_AFTER_N8N_CUTOVER=PASS",
        "SPC001_N8N_CUTOVER=PASS",
        "SPC001_N8N_CUTOVER_POST_RUNTIME=PASS",
        "SPC001_TENANCY_AUDIT=PASS",
        "SPC001_LIVE_POST_MIGRATION_VERIFY=PASS",
    )),
    "preview_accepts_only_post_e2_control_delta": (
        "git merge-base --is-ancestor" in RUNNER
        and "E2_TO_PREVIEW_CONTROL_DELTA=PASS" in RUNNER
        and "scripts/spc001-preview-apply.sh|scripts/spc001-preview-source-gate.py|.github/workflows/spc001-source-contract.yml" in RUNNER
        and "runtime-relevant source changed after accepted E2" in RUNNER
    ),
    "preview_runs_frontend_quality_gates_before_mutation": (
        RUNNER.index("npm ci") < RUNNER.index("preview_mutated=1")
        and RUNNER.index("npm run lint") < RUNNER.index("preview_mutated=1")
        and RUNNER.index("npm run build") < RUNNER.index("preview_mutated=1")
        and "FRONTEND_BUILD=PASS" in RUNNER
    ),
    "preview_backs_up_before_rsync_and_rolls_back": (
        RUNNER.index("preview.before.tgz") < RUNNER.index("rsync -a --delete")
        and "PREVIEW_BACKUP=PASS" in RUNNER
        and "PREVIEW_ROLLBACK=PASS" in RUNNER
        and "trap rollback_on_error ERR" in RUNNER
    ),
    "preview_proves_remote_artifact_identity": all(x in RUNNER for x in (
        "PREVIEW_INDEX_IDENTITY=PASS",
        "ASSET_IDENTITY=PASS",
        "PREVIEW_ARTIFACT_IDENTITY=PASS",
        "Cache-Control: no-cache",
    )),
    "preview_is_preview_only": (
        "DB_MUTATION=NONE" in RUNNER
        and "N8N_MUTATION=NONE" in RUNNER
        and "PRODUCTION_FRONTEND_MUTATION=NONE" in RUNNER
        and "PREVIEW_MUTATION=APPLIED" in RUNNER
        and "SPC001_PREVIEW_DEPLOY=PASS" in RUNNER
        and "docker exec" not in RUNNER
        and "psql" not in RUNNER
        and "prod-h2-backup-now.sh" not in RUNNER
        and "n8n import:workflow" not in RUNNER
        and "n8n publish:workflow" not in RUNNER
    ),
    "preview_writes_durable_evidence_manifest": all(x in RUNNER for x in (
        "preview-metadata.txt",
        "local-dist.sha256",
        "asset-identity.txt",
        "SHA256SUMS",
        "SPC001_PREVIEW_EVIDENCE_DIR=",
    )),
    "miniapp_space_gate_is_active": (
        "import SpaceGate from './SpaceGate.jsx'" in MAIN
        and "<SpaceGate>" in MAIN
        and "</SpaceGate>" in MAIN
    ),
    "miniapp_switch_clears_old_space_before_new_load": (
        "clearActiveSpaceId()" in SPACE_GATE
        and "setActiveSpace(null)" in SPACE_GATE
        and "await persistActiveSpace(target.id)" in SPACE_GATE
        and 'key={activeSpace.id}' in SPACE_GATE
    ),
    "miniapp_financial_requests_carry_untrusted_space_hint": (
        "X-MoneyTrack-Space-Id" in API
        and "getActiveSpaceId()" in API
        and "untrusted routing input" in API
    ),
    "mobile_space_creation_control_is_usable": (
        "@media (max-width: 430px)" in SPACE_CSS
        and "flex-wrap: wrap" in SPACE_CSS
        and "position: static" in SPACE_CSS
        and "clip-path: none" in SPACE_CSS
        and "flex: 1 1 auto" in SPACE_CSS
        and "width: 1px" not in SPACE_CSS
        and "height: 1px" not in SPACE_CSS
    ),
    "new_space_switch_uses_refreshed_list": (
        "availableSpaces = spaces" in SPACE_GATE
        and "availableSpaces.find((space) => space.id === targetId)" in SPACE_GATE
        and "await switchSpace(createdId, nextSpaces)" in SPACE_GATE
    ),
    "f2r1_requires_accepted_f1_and_exact_safe_delta": all(x in CORRECTIVE for x in (
        "SPC001_PREVIEW_DEPLOY=PASS",
        "sha256sum -c SHA256SUMS",
        "git merge-base --is-ancestor",
        "F1_TO_F2R1_SAFE_DELTA=PASS",
        "miniapp/src/SpaceGate.jsx|miniapp/src/spc001-space.css|scripts/spc001-f2r1-preview-apply.sh|scripts/spc001-preview-source-gate.py",
        "non-F2R1 source changed after accepted F1",
    )),
    "f2r1_is_preview_only_with_rollback_and_identity": (
        CORRECTIVE.index("npm run build") < CORRECTIVE.index("preview_mutated=1")
        and CORRECTIVE.index("preview.before.tgz") < CORRECTIVE.index("rsync -a --delete")
        and "PREVIEW_ROLLBACK=PASS" in CORRECTIVE
        and "PREVIEW_INDEX_IDENTITY=PASS" in CORRECTIVE
        and "ASSET_IDENTITY=PASS" in CORRECTIVE
        and "PRODUCTION_FRONTEND_MUTATION=NONE" in CORRECTIVE
        and "DB_MUTATION=NONE" in CORRECTIVE
        and "N8N_MUTATION=NONE" in CORRECTIVE
        and "docker exec" not in CORRECTIVE
        and "psql" not in CORRECTIVE
        and "n8n import:workflow" not in CORRECTIVE
    ),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_PREVIEW_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
print("N8N_MUTATION=NONE")
print("PREVIEW_MUTATION=NONE")
print("PRODUCTION_FRONTEND_MUTATION=NONE")
sys.exit(1 if failed else 0)
