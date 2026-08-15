#!/usr/bin/env python3
"""Source-only gate for SPC-001 invite runtime configuration apply."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "scripts/spc001-invite-runtime-apply.sh").read_text(encoding="utf-8")
OVERLAY = (ROOT / "ops/spc001/docker-compose.spc001.yml").read_text(encoding="utf-8")

checks = {
    "invite_overlay_requires_both_runtime_values": all(x in OVERLAY for x in (
        "MONEYTRACK_INVITE_TTL_SECONDS",
        "MONEYTRACK_INVITE_BASE_URL",
        ":?MONEYTRACK_INVITE_TTL_SECONDS is required",
        ":?MONEYTRACK_INVITE_BASE_URL is required",
    )),
    "invite_apply_requires_explicit_apply_exact_head_and_f3_evidence": all(x in RUNNER for x in (
        "explicit_--apply_required",
        "--expected-head",
        "--f3-dir",
        "SPC001_SHARED_PREVIEW=PASS",
        "F3_TO_INVITE_RUNTIME_SAFE_DELTA=PASS",
        "git merge-base --is-ancestor",
    )),
    "invite_apply_uses_protected_interpolation_context": all(x in RUNNER for x in (
        "compose-interpolation.prod-h.sh",
        'source "$INTERPOLATION"',
        "set -a",
        "set +a",
        "MONEYTRACK_PIN_PEPPER",
    )),
    "invite_apply_installs_source_controlled_overlay": all(x in RUNNER for x in (
        "ops/spc001/docker-compose.spc001.yml",
        "docker-compose.spc001.yml",
        'install -m 0644 "$OVERLAY_SOURCE" "$OVERLAY_TARGET"',
    )),
    "invite_apply_uses_complete_compose_stack": all(x in RUNNER for x in (
        '"$BASE_COMPOSE"',
        '"$HARDENING_COMPOSE"',
        '"$SEC_OVERLAY"',
        '"$OVERLAY_TARGET"',
        "docker compose -p n8n",
    )),
    "invite_apply_is_config_only": (
        "DB_MUTATION=NONE" in RUNNER
        and "N8N_MUTATION=CONFIG_RECREATE_APPLIED" in RUNNER
        and "N8N_WORKFLOW_IMPORT=NONE" in RUNNER
        and "N8N_WORKFLOW_PUBLISH=NONE" in RUNNER
        and "FRONTEND_MUTATION=NONE" in RUNNER
        and "psql" not in RUNNER
        and "n8n import:workflow" not in RUNNER
        and "n8n publish:workflow" not in RUNNER
    ),
    "invite_apply_has_backup_rollback_health_and_identity": all(x in RUNNER for x in (
        "CONFIG_BACKUP=PASS",
        "CONFIG_SOURCE_ROLLBACK=PASS",
        "N8N_CONFIG_ROLLBACK=PASS",
        "N8N_HEALTH=PASS",
        "LIVE_INVITE_ENV=PASS",
        "WORKFLOW_STATE_UNCHANGED=PASS",
        "SPC001_INVITE_RUNTIME_CONFIG=PASS",
    )),
    "invite_base_url_is_telegram_main_miniapp_derived": all(x in RUNNER for x in (
        "api.telegram.org",
        "has_main_web_app",
        'INVITE_BASE_URL="https://t.me/${BOT_USERNAME}"',
        "INVITE_TTL_SECONDS=86400",
    )),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_INVITE_RUNTIME_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
print("N8N_MUTATION=NONE")
print("FRONTEND_MUTATION=NONE")
sys.exit(1 if failed else 0)
