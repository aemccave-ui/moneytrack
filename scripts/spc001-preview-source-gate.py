#!/usr/bin/env python3
"""Source-only gate for SPC-001 preview, shared-Space UI, and F4 recovery."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNNER = (ROOT / "scripts/spc001-preview-apply.sh").read_text(encoding="utf-8")
CORRECTIVE = (ROOT / "scripts/spc001-f2r1-preview-apply.sh").read_text(encoding="utf-8")
SHARED = (ROOT / "scripts/spc001-shared-preview-apply.sh").read_text(encoding="utf-8")
F4_DB = (ROOT / "scripts/spc001-f4-member-read-apply.sh").read_text(encoding="utf-8")
F4_PREVIEW = (ROOT / "scripts/spc001-f4-preview-apply.sh").read_text(encoding="utf-8")
MAIN = (ROOT / "miniapp/src/main.jsx").read_text(encoding="utf-8")
SPACE_GATE = (ROOT / "miniapp/src/SpaceGate.jsx").read_text(encoding="utf-8")
SPACE_CSS = (ROOT / "miniapp/src/spc001-space.css").read_text(encoding="utf-8")
API = (ROOT / "miniapp/src/api.js").read_text(encoding="utf-8")
API_ERRORS = (ROOT / "miniapp/src/api-errors.js").read_text(encoding="utf-8")
MEMBER_SQL = (ROOT / "db/domain/SPC-001/123_space_member_identity_read.sql").read_text(encoding="utf-8")

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
    "shared_space_admin_ui_uses_existing_owner_boundaries": all(x in SPACE_GATE for x in (
        "activeSpace.is_owner",
        "createSpaceInvite(activeSpace.id)",
        "getSpaceMembers(space.id)",
        "removeSpaceMember(activeSpace.id, member.user_id)",
        "revokeSpaceInvite(invite.id)",
        "Совместный доступ",
        "Участники",
    )),
    "shared_space_invite_is_user_shareable_and_revocable": all(x in SPACE_GATE for x in (
        "created?.invite_url",
        "navigator.clipboard?.writeText",
        "https://t.me/share/url?url=",
        "Ссылка приглашения",
        "Приглашение отозвано",
    )),
    "default_capture_space_is_explicit_and_plain_language": (
        "defaultCaptureSpaceId" in SPACE_GATE
        and "setDefaultCaptureSpace(activeSpace.id)" in SPACE_GATE
        and "Операции из бота" in SPACE_GATE
        and "Записывать сюда" in SPACE_GATE
        and "Новые операции, отправленные в Telegram-бот" in SPACE_GATE
        and "Использовать для бота" not in SPACE_GATE
    ),
    "invite_receiver_onboarding_is_preserved": all(x in SPACE_GATE for x in (
        "telegramInviteStartParam()",
        "acceptTelegramInviteOnce()",
        "startsWith('invite_')",
        "invitedSpaceId",
    )),
    "shared_preview_requires_accepted_f2r1_and_exact_safe_delta": all(x in SHARED for x in (
        "SPC001_F2R1_PREVIEW=PASS",
        "sha256sum -c SHA256SUMS",
        "git merge-base --is-ancestor",
        "F2R1_TO_SHARED_UI_SAFE_DELTA=PASS",
        "miniapp/src/SpaceGate.jsx|miniapp/src/spc001-space.css|scripts/spc001-shared-preview-apply.sh|scripts/spc001-preview-source-gate.py",
        "non-shared-UI source changed after accepted F2R1",
    )),
    "shared_preview_is_preview_only_with_rollback_and_identity": (
        SHARED.index("npm run build") < SHARED.index("preview_mutated=1")
        and SHARED.index("preview.before.tgz") < SHARED.index("rsync -a --delete")
        and "PREVIEW_ROLLBACK=PASS" in SHARED
        and "PREVIEW_INDEX_IDENTITY=PASS" in SHARED
        and "ASSET_IDENTITY=PASS" in SHARED
        and "SPC001_SHARED_PREVIEW=PASS" in SHARED
        and "PRODUCTION_FRONTEND_MUTATION=NONE" in SHARED
        and "DB_MUTATION=NONE" in SHARED
        and "N8N_MUTATION=NONE" in SHARED
        and "docker exec" not in SHARED
        and "psql" not in SHARED
        and "n8n import:workflow" not in SHARED
    ),
    "f4_space_access_loss_dispatches_central_recovery": all(x in API_ERRORS for x in (
        "SPACE_CONTEXT_NOT_FOUND",
        "SPACE_NOT_FOUND_OR_NOT_MEMBER",
        "moneytrack:space-invalid",
    )) and all(x in SPACE_GATE for x in (
        "recoverSpaceAccess",
        "moneytrack:space-invalid",
        "clearActiveSpaceId()",
        "setActiveSpace(null)",
        "const payload = await getSpaces()",
        "MoneyTrack переключил вас на доступное пространство",
    )),
    "f4_space_picker_is_custom_single_row": (
        "<select" not in SPACE_GATE
        and "spacePickerTrigger" in SPACE_GATE
        and "spacePickerSheet" in SPACE_GATE
        and "Добавить пространство" in SPACE_GATE
        and "Совместный доступ" in SPACE_GATE
        and "flex-wrap: wrap" not in SPACE_CSS
        and "grid-template-columns: minmax(0, 1fr) auto" in SPACE_CSS
    ),
    "f4_background_fill_covers_space_gate": all(x in SPACE_CSS for x in (
        "min-height: 100dvh",
        "radial-gradient",
        "linear-gradient(180deg",
        "backdrop-filter: blur(18px)",
    )),
    "f4_member_read_adds_display_identity_only": (
        "create or replace function moneytrack.space_members_api_read_v1" in MEMBER_SQL
        and "assert_space_owner_v1" in MEMBER_SQL
        and "first_name" in MEMBER_SQL
        and "username" in MEMBER_SQL
        and "telegram_user_id" not in MEMBER_SQL
        and "member.first_name" in SPACE_GATE
        and "member.username" in SPACE_GATE
        and "Пользователь #" in SPACE_GATE
    ),
    "f4_member_read_apply_is_controlled_and_reversible": all(x in F4_DB for x in (
        "explicit_--apply_required",
        "SPC001_INVITE_RUNTIME_CONFIG=PASS",
        "INVITE_RUNTIME_TO_F4_SAFE_DELTA=PASS",
        "space-members-api.before.sql",
        "pg_get_functiondef",
        "315_verify_live_post_migration_readonly.sql",
        "LIVE_315_UNCHANGED=PASS",
        "F4_MEMBER_READ_ROLLBACK=PASS",
        "FINANCIAL_DATA_MUTATION=NONE",
        "N8N_MUTATION=NONE",
    )),
    "f4_preview_requires_exact_runtime_evidence_and_is_preview_only": (
        all(x in F4_PREVIEW for x in (
            "SPC001_SHARED_PREVIEW=PASS",
            "SPC001_INVITE_RUNTIME_CONFIG=PASS",
            "SPC001_F4_MEMBER_READ=PASS",
            "INVITE_RUNTIME_TO_F4_SAFE_DELTA=PASS",
            "PREVIEW_BACKUP=PASS",
            "PREVIEW_ROLLBACK=PASS",
            "PREVIEW_ARTIFACT_IDENTITY=PASS",
            "SPC001_F4_PREVIEW=PASS",
            "DB_MUTATION=NONE",
            "N8N_MUTATION=NONE",
            "PRODUCTION_FRONTEND_MUTATION=NONE",
        ))
        and F4_PREVIEW.index("npm run build") < F4_PREVIEW.index("preview_mutated=1")
        and F4_PREVIEW.index("preview.before.tgz") < F4_PREVIEW.index("rsync -a --delete")
        and "docker exec" not in F4_PREVIEW
        and "psql" not in F4_PREVIEW
        and "n8n import:workflow" not in F4_PREVIEW
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
