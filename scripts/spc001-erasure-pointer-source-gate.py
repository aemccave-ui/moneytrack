#!/usr/bin/env python3
"""SPC-001 source-only gate for owner erasure Space-pointer ordering."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ERASURE = ROOT / "db/domain/SPC-001/120_user_erasure_guard.sql"
VERIFY = ROOT / "db/domain/SPC-001/190_verify_space_lifecycle.sql"


def require(label: str, condition: bool) -> None:
    if not condition:
        raise SystemExit(f"SPC001_ERASURE_POINTER_SOURCE_GATE=FAIL {label}")
    print(f"{label}=PASS")


def main() -> None:
    erasure = ERASURE.read_text(encoding="utf-8")
    verify = VERIFY.read_text(encoding="utf-8")
    low = erasure.lower()

    current_update = "where us.current_workspace_id=any(v_owned_space_ids);"
    capture_update = "where us.default_capture_space_id=any(v_owned_space_ids);"
    workspace_delete = "delete from moneytrack.workspaces w\n         where w.id=any(v_owned_space_ids);"
    blocked_gate = "if cardinality(v_blocked_space_ids)>0 then"

    require(
        "owner_erasure_clears_current_space_pointer_for_all_users",
        current_update in low
        and "us.user_id<>p_user_id" not in low,
    )
    require(
        "owner_erasure_clears_default_capture_pointer_for_all_users",
        capture_update in low,
    )
    require(
        "owner_erasure_clears_space_pointers_before_workspace_delete",
        low.index(current_update) < low.index(workspace_delete)
        and low.index(capture_update) < low.index(workspace_delete),
    )
    require(
        "owner_transfer_gate_precedes_destructive_erasure",
        low.index(blocked_gate) < low.index("update moneytrack.user_delete_requests")
        < low.index(workspace_delete),
    )
    require(
        "lifecycle_verifier_exercises_member_and_owner_erasure",
        "MEMBER_ERASURE_SHARED_HISTORY=PASS" in verify
        and "OWNER_ERASURE_FAIL_CLOSED=PASS" in verify
        and "user_delete_me_v1" in verify
        and verify.lower().rstrip().endswith("rollback;"),
    )

    print("SPC001_ERASURE_POINTER_SOURCE_GATE=PASS")
    print("RUNTIME_DB_EVIDENCE=NOT_CLAIMED")
    print("DB_MUTATION=NONE")


if __name__ == "__main__":
    main()
