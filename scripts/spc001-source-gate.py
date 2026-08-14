#!/usr/bin/env python3
"""MoneyTrack SPC-001 source gate.

The verifier is stage-aware so A/B/C can close independently without falsely
claiming future-stage invariants. Every final SPC invariant is printed on every
run as PASS, FAIL or DEFERRED. FINAL accepts no DEFERRED values.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    p = ROOT / path
    if not p.is_file():
        return ""
    return p.read_text(encoding="utf-8")


def has_all(text: str, *needles: str) -> bool:
    return all(n in text for n in needles)


def status(value: bool | None) -> str:
    if value is None:
        return "DEFERRED"
    return "PASS" if value else "FAIL"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=("A", "B", "C", "FINAL"), default="A")
    args = parser.parse_args()

    forensic = read("docs/architecture/SPC-001-tenancy-forensic.md")
    foundation = read("db/domain/SPC-001/010_tenancy_foundation.sql")
    uniqueness = read("db/domain/SPC-001/012_tenancy_uniqueness_hardening.sql")
    actor_erasure = read("db/domain/SPC-001/013_actor_erasure_fk_hardening.sql")
    bootstrap = read("db/domain/SPC-001/014_space_bootstrap.sql")
    finance = read("db/domain/SPC-001/020_space_finance_domain.sql")
    finance_hardening = read("db/domain/SPC-001/021_space_finance_hardening.sql")
    verify_a = read("db/domain/SPC-001/090_verify_tenancy_foundation.sql")
    lifecycle = read("db/domain/SPC-001/110_space_lifecycle.sql")
    erasure = read("db/domain/SPC-001/120_user_erasure_guard.sql")
    capture = read("db/domain/SPC-001/210_capture_projection.sql")
    workflow = read(".github/workflows/moneytrack-source-gates.yml")
    sec = read("db/domain/SEC-001/010_application_lock.sql")
    ux024 = read("db/domain/UX-024/010_operation_source_and_datetime_guard.sql")

    stage_a_complete = bool(
        foundation
        and uniqueness
        and actor_erasure
        and bootstrap
        and finance
        and finance_hardening
        and verify_a
    )
    stage_b_complete = bool(lifecycle and erasure)
    stage_c_complete = bool(capture)

    checks: dict[str, bool | None] = {
        "space_is_financial_tenant": has_all(
            foundation,
            "space_id bigint references moneytrack.workspaces(id)",
            "SPC-001 canonical financial tenant",
        ),
        "owner_is_admin_not_financial_role": has_all(
            foundation,
            "assert_space_member_v1",
            "Owner role is intentionally NOT inspected for financial authorization",
            "assert_space_owner_v1",
            "administration-only owner assertion",
        ),
        "all_members_financially_equal": has_all(
            foundation,
            "Active membership, not owner role, grants ordinary Space financial access",
        ) and (
            has_all(finance, "assert_space_member_v1")
            and has_all(finance_hardening, "assert_space_member_v1")
            if stage_a_complete
            else True
        ),
        "membership_server_side": has_all(
            foundation,
            "assert_space_member_v1",
            "SPACE_NOT_FOUND_OR_NOT_MEMBER",
        ),
        "client_space_id_untrusted": has_all(
            forensic,
            "client-provided Space id remains untrusted",
        ) and (
            has_all(finance, "assert_space_member_v1")
            and has_all(finance_hardening, "assert_space_member_v1")
            if stage_a_complete
            else True
        ),
        "legacy_user_data_migrated": has_all(
            foundation,
            "spc001_personal_space_for_user_v1",
            "legacy_migration",
            "Template sentinel user 0 remains GLOBAL_PLATFORM",
        ),
        "financial_uniqueness_space_scoped": (
            has_all(
                uniqueness,
                "ux_spc001_accounts_space_code",
                "ux_spc001_categories_space_code",
                "ux_spc001_products_space_key",
                "ux_spc001_transactions_space_source",
                "ux_spc001_transfers_space_source",
                "user_id = 0 and space_id is null",
            )
            and has_all(
                uniqueness,
                "array['user_id','code']",
                "array['user_id','product_key']",
                "ux_transactions_source_idempotency",
                "ux_transfers_source_idempotency",
            )
            if stage_a_complete
            else None
        ),
        "new_user_bootstrap_space_scoped": (
            has_all(
                bootstrap,
                "spc001_user_bootstrap_v1",
                "spc001_bootstrap_space_finance_v1",
                "catalog_ensure_space_categories_v1",
                "on conflict (space_id, code) where space_id is not null",
                "current_workspace_id",
                "assert_space_member_v1",
            )
            if stage_a_complete
            else None
        ),
        "financial_data_space_scoped": (
            has_all(
                finance,
                "p_actor_user_id",
                "p_space_id",
                "assert_space_member_v1",
            )
            and has_all(
                finance_hardening,
                "p_actor_user_id",
                "p_space_id",
                "assert_space_member_v1",
            )
            if stage_a_complete
            else None
        ),
        "user_global_security_remains_user_global": has_all(
            sec,
            "create table if not exists moneytrack.user_security",
            "user_id bigint primary key",
            "create table if not exists moneytrack.user_unlock_sessions",
        ) and "space_id" not in sec,
        "financial_references_do_not_cross_spaces": has_all(
            foundation,
            "SPC001_TRANSACTION_ACCOUNT_CROSS_SPACE",
            "SPC001_TRANSACTION_CATEGORY_CROSS_SPACE",
            "SPC001_TRANSFER_FROM_ACCOUNT_CROSS_SPACE",
            "SPC001_TRANSFER_TO_ACCOUNT_CROSS_SPACE",
            "SPC001_BUDGET_CATEGORY_CROSS_SPACE",
            "SPC001_DEFAULT_ACCOUNT_CROSS_SPACE",
        ),
        "operation_author_preserved": has_all(
            foundation,
            "created_by_user_id",
            "preserves original author independently of Space ownership",
        ) and (
            has_all(finance, "created_by_user_id", "updated_by_user_id")
            and has_all(actor_erasure, "on delete set null", "Financial history remains Space-owned")
            if stage_a_complete
            else True
        ),
        "stage_a_finance_hardening_present": (
            has_all(
                finance_hardening,
                "Correctness layer over 020_space_finance_domain.sql",
                "finance_create_transaction_space_v1",
                "finance_create_transfer_space_v1",
                "finance_dashboard_space_read_model_v1",
            )
            if stage_a_complete
            else None
        ),
        "dashboard_balance_no_join_multiplication": (
            has_all(
                finance_hardening,
                "tx_movements as (",
                "transfer_movements as (",
                "select * from tx_movements union all select * from transfer_movements",
                "raw_balances as (",
            )
            if stage_a_complete
            else None
        ),
        "actor_erasure_fk_shared_history_safe": (
            has_all(
                actor_erasure,
                "created_by_user_id",
                "updated_by_user_id",
                "captured_by_user_id",
                "on delete set null",
                "Shared finance history must survive user erasure",
            )
            if stage_a_complete
            else None
        ),
        "stage_a_verifier_is_rollback_only": (
            has_all(
                verify_a,
                "always rolled back",
                "TENANT_ISOLATION=PASS",
                "SHARED_FINANCIAL_RIGHTS=PASS",
                "MEMBER_REMOVAL_IMMEDIATE=PASS",
                "rollback;",
            )
            if stage_a_complete
            else None
        ),
        "capture_event_multi_projection": (
            has_all(capture, "capture_event", "space_id", "projection")
            if stage_c_complete
            else None
        ),
        "multi_space_postings_independent": (
            has_all(capture, "MULTI_SPACE", "independent")
            if stage_c_complete
            else None
        ),
        "hidden_space_linkage_not_leaked": (
            has_all(capture, "assert_space_member_v1", "accessible", "projection")
            if stage_c_complete
            else None
        ),
        "receipt_classification_space_specific": (
            has_all(capture, "receipt_item", "transaction_id", "category_id")
            if stage_c_complete
            else None
        ),
        "transfer_single_space_only": has_all(
            foundation,
            "SPC001_TRANSFER_FROM_ACCOUNT_CROSS_SPACE",
            "SPC001_TRANSFER_TO_ACCOUNT_CROSS_SPACE",
        ) and (
            has_all(finance_hardening, "space_id", "from_account_id", "to_account_id")
            if stage_a_complete
            else True
        ),
        "bot_default_capture_space_explicit": (
            has_all(lifecycle, "default_capture_space", "assert_space_member_v1")
            if stage_b_complete
            else None
        ),
        "bot_not_last_active_space": (
            has_all(lifecycle, "default_capture_space", "last active")
            if stage_b_complete
            else None
        ),
        "invite_token_opaque": (
            has_all(lifecycle, "token_hash", "opaque") if stage_b_complete else None
        ),
        "invite_single_use_expiry_revoke": (
            has_all(lifecycle, "accepted_at", "expires_at", "revoked_at")
            if stage_b_complete
            else None
        ),
        "member_removal_immediate": (
            has_all(lifecycle, "removed", "assert_space_member_v1")
            if stage_b_complete
            else None
        ),
        "space_switch_clears_old_context": (
            has_all(lifecycle, "active Space", "clear") if stage_b_complete else None
        ),
        "dashboard_single_space_only": (
            has_all(finance_hardening, "finance_dashboard", "p_space_id")
            if stage_a_complete
            else None
        ),
        "user_erasure_shared_space_safe": (
            has_all(erasure, "shared", "fail", "owner") if stage_b_complete else None
        ),
        "ux022_contract_preserved": "UX-022" in forensic,
        "ux023_contract_preserved": "UX-023" in forensic,
        "ux024_contract_preserved": has_all(
            ux024,
            "photo_receipt",
            "RECEIPT_DATETIME_IMMUTABLE",
        ) and "UX-024" in forensic,
        "sec001_contract_preserved": has_all(
            sec,
            "user_unlock_sessions",
            "pin_verifier",
        ) and "SEC-001" in forensic,
        "production_not_targeted": has_all(
            forensic,
            "PRODUCTION_MUTATION=NONE",
        ),
    }

    required_by_stage = {
        "A": {
            "space_is_financial_tenant",
            "owner_is_admin_not_financial_role",
            "all_members_financially_equal",
            "membership_server_side",
            "client_space_id_untrusted",
            "legacy_user_data_migrated",
            "financial_uniqueness_space_scoped",
            "new_user_bootstrap_space_scoped",
            "financial_data_space_scoped",
            "user_global_security_remains_user_global",
            "financial_references_do_not_cross_spaces",
            "operation_author_preserved",
            "stage_a_finance_hardening_present",
            "dashboard_balance_no_join_multiplication",
            "actor_erasure_fk_shared_history_safe",
            "stage_a_verifier_is_rollback_only",
            "transfer_single_space_only",
            "dashboard_single_space_only",
            "ux022_contract_preserved",
            "ux023_contract_preserved",
            "ux024_contract_preserved",
            "sec001_contract_preserved",
            "production_not_targeted",
        },
        "B": set(),
        "C": set(),
        "FINAL": set(checks),
    }
    required_by_stage["B"] = required_by_stage["A"] | {
        "bot_default_capture_space_explicit",
        "bot_not_last_active_space",
        "invite_token_opaque",
        "invite_single_use_expiry_revoke",
        "member_removal_immediate",
        "space_switch_clears_old_context",
        "user_erasure_shared_space_safe",
    }
    required_by_stage["C"] = required_by_stage["B"] | {
        "capture_event_multi_projection",
        "multi_space_postings_independent",
        "hidden_space_linkage_not_leaked",
        "receipt_classification_space_specific",
    }

    print(f"SPC001_SOURCE_GATE_STAGE={args.stage}")
    for name, value in checks.items():
        print(f"{name}={status(value)}")

    failures = [
        name
        for name in required_by_stage[args.stage]
        if checks[name] is not True
    ]

    if "SPC-001 source gate" not in workflow:
        failures.append("github_actions_spc_gate_missing")

    if failures:
        print("SPC001_SOURCE_GATE=FAIL")
        print("failures=" + ",".join(sorted(set(failures))))
        return 1

    print("SPC001_SOURCE_GATE=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
