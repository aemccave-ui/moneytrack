#!/usr/bin/env python3
"""Source-only guard for the SPC-001 capture projection synthetic verifier."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
VERIFY = (ROOT / "db/domain/SPC-001/290_verify_capture_projection.sql").read_text(encoding="utf-8")
BUILDER = (ROOT / "scripts/spc001-build-db-migration.py").read_text(encoding="utf-8")
GROUP_GUARD = (ROOT / "db/domain/UX-022/040_grouping_account_invariant.sql").read_text(encoding="utf-8")
VERIFY_LOWER = VERIFY.lower()

checks = {
    "capture_verifier_personal_account_is_postable_leaf": (
        "ux022_account_has_active_children_v1(pa.user_id,pa.id)" in VERIFY
        and "not moneytrack.ux022_account_has_active_children_v1(pa.user_id,pa.id)" in VERIFY
    ),
    "capture_verifier_family_account_is_postable_leaf": (
        "ux022_account_has_active_children_v1(fa.user_id,fa.id)" in VERIFY
        and "not moneytrack.ux022_account_has_active_children_v1(fa.user_id,fa.id)" in VERIFY
    ),
    "capture_verifier_personal_account_matches_transaction_currency": (
        "select upper(s.base_currency) into v_currency" in VERIFY
        and "upper(pa.currency_code)=v_currency" in VERIFY
    ),
    "capture_verifier_family_account_matches_transaction_currency": (
        "upper(fa.currency_code)=v_currency" in VERIFY
    ),
    "capture_verifier_preserves_ux022_group_guard": (
        "ACCOUNT_GROUP_NOT_POSTABLE" in GROUP_GUARD
        and "ux022_transactions_group_posting_guard" in GROUP_GUARD
        and "disable trigger" not in VERIFY_LOWER
    ),
    "capture_verifier_is_synthetic_rollback_only": (
        "Synthetic state is transaction-local and always rolled back" in VERIFY
        and VERIFY.rstrip().lower().endswith("rollback;")
    ),
    "capture_verifier_not_in_migration_program": (
        '"290_verify_capture_projection.sql"' not in BUILDER
    ),
}

failed = False
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed = failed or not ok

print(f"SPC001_CAPTURE_VERIFIER_SOURCE_GATE={'FAIL' if failed else 'PASS'}")
print("RUNTIME_DB_EVIDENCE=NOT_CLAIMED")
print("DB_MUTATION=NONE")
sys.exit(1 if failed else 0)
