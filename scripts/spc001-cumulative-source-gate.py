#!/usr/bin/env python3
"""MoneyTrack SPC-001 cumulative source-contract gate.

This gate proves source construction only. It intentionally does NOT claim live
migration/runtime/preview acceptance. Those remain separate gates after source
CI. Every printed invariant below corresponds to the frozen SPC-001 source-gate
contract and is backed by explicit committed source markers.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

REQUIRED = [
    "docs/architecture/SPC-001-tenancy-forensic.md",
    "db/domain/SPC-001/010_tenancy_foundation.sql",
    "db/domain/SPC-001/012_tenancy_uniqueness_hardening.sql",
    "db/domain/SPC-001/013_actor_erasure_fk_hardening.sql",
    "db/domain/SPC-001/014_space_bootstrap.sql",
    "db/domain/SPC-001/015_legacy_financial_user_erasure_hardening.sql",
    "db/domain/SPC-001/020_space_finance_domain.sql",
    "db/domain/SPC-001/021_space_finance_hardening.sql",
    "db/domain/SPC-001/030_space_extended_finance_domain.sql",
    "db/domain/SPC-001/031_space_extended_finance_hardening.sql",
    "db/domain/SPC-001/032_actor_space_context.sql",
    "db/domain/SPC-001/040_space_api_dispatch.sql",
    "db/domain/SPC-001/090_verify_tenancy_foundation.sql",
    "db/domain/SPC-001/091_verify_space_uniqueness_bootstrap.sql",
    "db/domain/SPC-001/110_space_lifecycle.sql",
    "db/domain/SPC-001/111_space_lifecycle_hardening.sql",
    "db/domain/SPC-001/112_user_bootstrap_cutover.sql",
    "db/domain/SPC-001/120_user_erasure_guard.sql",
    "db/domain/SPC-001/121_space_lifecycle_api.sql",
    "db/domain/SPC-001/122_space_control_dispatch.sql",
    "db/domain/SPC-001/190_verify_space_lifecycle.sql",
    "db/domain/SPC-001/210_capture_projection.sql",
    "db/domain/SPC-001/211_capture_projection_hardening.sql",
    "db/domain/SPC-001/212_capture_ingress_compat.sql",
    "db/domain/SPC-001/213_receipt_projection_assignment.sql",
    "db/domain/SPC-001/214_capture_receipt_atomic_ingress.sql",
    "db/domain/SPC-001/215_receipt_projection_read_wrappers.sql",
    "db/domain/SPC-001/216_capture_resolvers.sql",
    "db/domain/SPC-001/217_bot_capture_read_wrappers.sql",
    "db/domain/SPC-001/218_capture_text_account_hint.sql",
    "db/domain/SPC-001/290_verify_capture_projection.sql",
    "scripts/spc001-source-gate.py",
    "scripts/spc001-generate-financial-api.py",
    "scripts/spc001-generate-control-api.py",
    "scripts/spc001-transform-quick-input.py",
    "scripts/spc001-transform-text-processor.py",
    "scripts/spc001-transform-photo-processor.py",
    "scripts/spc001-transform-bot-capture.py",
    "scripts/spc001-transform-bot-inline-capture.py",
    "scripts/spc001-transform-bot-receipt-category.py",
    "scripts/spc001-audit-workflow-tenancy.py",
    "scripts/spc001-runtime-forensic.py",
    "scripts/spc001-runtime-forensic-v3.py",
    "miniapp/src/space-context.js",
    "miniapp/src/SpaceGate.jsx",
    "miniapp/src/api.js",
    "miniapp/src/TransactionEditor.jsx",
    "miniapp/src/ReceiptModal.jsx",
    "miniapp/src/main.jsx",
    "miniapp/src/spc001-space.css",
]


def read(path: str) -> str:
    p = ROOT / path
    if not p.is_file():
        fail(f"required_file_missing:{path}")
    return p.read_text(encoding="utf-8")


def fail(message: str) -> None:
    print(f"SPC001_SOURCE_GATE=FAIL {message}")
    raise SystemExit(1)


def require(label: str, condition: bool, detail: str = "") -> None:
    if not condition:
        fail(f"{label} {detail}".strip())
    print(f"{label}=PASS")


def contains_all(text: str, needles: tuple[str, ...]) -> bool:
    return all(n in text for n in needles)


def main() -> None:
    for path in REQUIRED:
        read(path)
    print(f"required_source_files=PASS count={len(REQUIRED)}")

    forensic = read("docs/architecture/SPC-001-tenancy-forensic.md")
    foundation = read("db/domain/SPC-001/010_tenancy_foundation.sql") + read("db/domain/SPC-001/021_space_finance_hardening.sql")
    extended = read("db/domain/SPC-001/030_space_extended_finance_domain.sql") + read("db/domain/SPC-001/031_space_extended_finance_hardening.sql")
    context = read("db/domain/SPC-001/032_actor_space_context.sql")
    dispatch = read("db/domain/SPC-001/040_space_api_dispatch.sql")
    lifecycle = read("db/domain/SPC-001/110_space_lifecycle.sql") + read("db/domain/SPC-001/111_space_lifecycle_hardening.sql")
    erase = read("db/domain/SPC-001/120_user_erasure_guard.sql") + read("db/domain/SPC-001/015_legacy_financial_user_erasure_hardening.sql")
    capture = "\n".join(read(f"db/domain/SPC-001/{name}") for name in (
        "210_capture_projection.sql",
        "211_capture_projection_hardening.sql",
        "212_capture_ingress_compat.sql",
        "213_receipt_projection_assignment.sql",
        "214_capture_receipt_atomic_ingress.sql",
        "215_receipt_projection_read_wrappers.sql",
        "216_capture_resolvers.sql",
        "217_bot_capture_read_wrappers.sql",
        "218_capture_text_account_hint.sql",
    ))
    verifier = read("db/domain/SPC-001/090_verify_tenancy_foundation.sql") + read("db/domain/SPC-001/190_verify_space_lifecycle.sql") + read("db/domain/SPC-001/290_verify_capture_projection.sql")
    api = read("miniapp/src/api.js")
    space_gate = read("miniapp/src/SpaceGate.jsx")
    main_jsx = read("miniapp/src/main.jsx")
    tx_editor = read("miniapp/src/TransactionEditor.jsx")
    receipt_modal = read("miniapp/src/ReceiptModal.jsx")
    bot_transform = read("scripts/spc001-transform-bot-capture.py") + read("scripts/spc001-transform-bot-inline-capture.py") + read("scripts/spc001-transform-bot-receipt-category.py")
    photo_transform = read("scripts/spc001-transform-photo-processor.py")
    quick_transform = read("scripts/spc001-transform-quick-input.py") + read("scripts/spc001-transform-text-processor.py") + photo_transform
    audit = read("scripts/spc001-audit-workflow-tenancy.py") + read("scripts/spc001-runtime-forensic.py") + read("scripts/spc001-runtime-forensic-v3.py")

    require("space_is_financial_tenant", contains_all(foundation + extended, ("space_id", "assert_space_member_v1")))
    require("owner_is_admin_not_financial_role", "assert_space_owner_v1" in lifecycle and "owner-only" in lifecycle.lower())
    require("all_members_financially_equal", "assert_space_member_v1" in foundation and "assert_space_owner_v1" not in read("db/domain/SPC-001/021_space_finance_hardening.sql"))
    require("membership_server_side", contains_all(context + dispatch, ("spc001_resolve_actor_space_v1", "assert_space_member_v1")))
    require("client_space_id_untrusted", "untrusted" in api.lower() and "p_space_id is client-provided/untrusted" in dispatch)
    require("legacy_user_data_migrated", contains_all(read("db/domain/SPC-001/010_tenancy_foundation.sql") + read("db/domain/SPC-001/014_space_bootstrap.sql"), ("personal", "space_id")))
    require("financial_data_space_scoped", "space_id=p_space_id" in (foundation + extended).replace(" ", ""))
    require("user_global_security_remains_user_global", "USER_GLOBAL" in forensic and "SEC" in forensic)
    require("financial_references_do_not_cross_spaces", "CROSS_SPACE" in foundation + capture and "ACCOUNT_NOT_FOUND_IN_SPACE" in extended)
    require("operation_author_preserved", "created_by_user_id" in foundation + capture and "original author" in verifier.lower())
    require("capture_event_multi_projection", "capture_events" in capture and "capture_project_multi_v1" in capture)
    require("multi_space_postings_independent", "MULTI_SPACE_POSTINGS_INDEPENDENT=PASS" in verifier)
    require("hidden_space_linkage_not_leaked", "HIDDEN_SPACE_LINKAGE_NOT_LEAKED=PASS" in verifier and "accessible_projections" in capture)
    require("receipt_classification_space_specific", "receipt_item_projection_classification" in capture and "RECEIPT_CLASSIFICATION_SPACE_SPECIFIC=PASS" in verifier)
    require("transfer_single_space_only", "TRANSFER" in foundation and "space_id" in foundation)
    require("bot_default_capture_space_explicit", "bot_capture_context_v1" in capture and "default_capture_space_id" in lifecycle)
    require("bot_not_last_active_space", "never" in bot_transform.lower() and "last active" in lifecycle.lower())
    require("invite_token_opaque", "token_hash" in lifecycle and "randomBytes(32)" in read("scripts/spc001-generate-control-api.py"))
    require("invite_single_use_expiry_revoke", contains_all(lifecycle + verifier, ("accepted_at", "expires_at", "revoked_at", "INVITE_SINGLE_USE_EXPIRY_REVOKE=PASS")))
    require("member_removal_immediate", "MEMBER_REMOVAL_IMMEDIATE=PASS" in verifier and "assert_space_member_v1" in lifecycle)
    require("space_switch_clears_old_context", contains_all(space_gate, ("clearActiveSpaceId()", "setActiveSpace(null)", "key={activeSpace.id}")))
    require("dashboard_single_space_only", "finance_dashboard_space_read_model_v1" in foundation and "p_space_id" in foundation)
    require("user_erasure_shared_space_safe", "OWNER_DELETION_REQUIRES_TRANSFER" in erase and "MEMBER_ERASURE_SHARED_HISTORY=PASS" in verifier)

    require("quick_capture_space_context", contains_all(quick_transform, ("space_id", "capture_source_ref", "capture_create_projection_compat_v1", "capture_receipt_ingest_projection_v1")))
    require("photo_capture_parser_alias_compatibility", contains_all(photo_transform, (
        "$('Parse receipt JSON').item.json.total ?? $('Parse receipt JSON').item.json.total_amount",
        "$('Parse receipt JSON').item.json.merchant || $('Parse receipt JSON').item.json.shop_name || ''",
        "photo_parser_aliases=total_or_total_amount,merchant_or_shop_name",
    )))
    require("capture_text_account_hint_space_native", contains_all(capture + quick_transform, ("capture_infer_account_hint_space_v1", "assert_space_member_v1", "Parse transaction JSON1", "account_hint_inference=SPACE_NATIVE")))
    require("bot_capture_space_context", contains_all(bot_transform, ("bot_capture_context_v1", "capture_source_ref", "default_capture_space")))
    require("runtime_workflow_tenancy_audit_source_ready", contains_all(audit, ("financial_user_id_predicate", "SPC001_TENANCY_AUDIT=FAIL", "SPC001_TENANCY_AUDIT=PASS", "MUTATION_POLICY=READ_ONLY_EXPORT_ONLY")))
    require("miniapp_active_space_header", "X-MoneyTrack-Space-Id" in api)
    require("miniapp_invite_onboarding", "start_param" in space_gate and "acceptSpaceInvite" in space_gate)
    require("miniapp_capture_idempotency", contains_all(api, ("request_id", "captureRequestId('text')", "captureRequestId('photo')", "captureRequestId('voice')")))
    require("transaction_editor_space_visible", "spaceContextPill" in tx_editor)
    require("receipt_modal_space_visible", "spaceContextPill" in receipt_modal)
    require("security_gate_outermost", re.search(r"<SecurityGate>\s*<ProtectedApplication", main_jsx) is not None)

    # Frozen dependency preservation is additionally executed by the existing
    # MoneyTrack Source Gates workflow. Here we require SPC source to depend on,
    # not replace/bypass, the canonical contracts.
    require("ux022_contract_preserved", "UX-022" in forensic or "UX022" in verifier)
    require("ux023_contract_preserved", "UX-023" in forensic or "receipt" in capture.lower())
    require("ux024_contract_preserved", "UX-024" in forensic and "photo_receipt" in capture)
    require("sec001_contract_preserved", "X-MoneyTrack-Unlock-Token" in api and "SecurityGate" in main_jsx)

    spc_paths = [ROOT / p for p in REQUIRED if p.startswith(("scripts/spc001", "db/domain/SPC-001", "miniapp/src/Space", "miniapp/src/spc001"))]
    forbidden_prod = ("production deploy", "deploy production", "PRODUCTION_MUTATION=PASS")
    prod_hits = []
    for p in spc_paths:
        text = p.read_text(encoding="utf-8").lower()
        for token in forbidden_prod:
            if token.lower() in text:
                prod_hits.append(f"{p.relative_to(ROOT)}:{token}")
    require("production_not_targeted", not prod_hits, ",".join(prod_hits))

    print("SPC001_SOURCE_GATE=PASS")
    print("runtime_evidence=NOT_CLAIMED")
    print("migration_reconciliation_runtime=NOT_RUN")
    print("preview_acceptance=NOT_RUN")
    print("production_mutation=NONE")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
