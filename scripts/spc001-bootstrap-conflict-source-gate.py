#!/usr/bin/env python3
"""Source-only guard against PL/pgSQL RETURNS TABLE / ON CONFLICT ambiguity."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "db/domain/SPC-001/014_space_bootstrap.sql"


def require(label: str, ok: bool) -> None:
    if not ok:
        raise SystemExit(f"SPC001_BOOTSTRAP_CONFLICT_SOURCE_GATE=FAIL {label}")
    print(f"{label}=PASS")


def function_body(text: str, signature: str, next_marker: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"SPC001_BOOTSTRAP_CONFLICT_SOURCE_GATE=FAIL missing={signature}")
    end = text.find(next_marker, start)
    if end < 0:
        end = len(text)
    return text[start:end]


def main() -> None:
    if not BOOTSTRAP.is_file():
        raise SystemExit("SPC001_BOOTSTRAP_CONFLICT_SOURCE_GATE=FAIL bootstrap_missing")
    text = BOOTSTRAP.read_text(encoding="utf-8")

    finance = function_body(
        text,
        "create or replace function moneytrack.spc001_bootstrap_space_finance_v1(",
        "comment on function moneytrack.spc001_bootstrap_space_finance_v1",
    )
    user = function_body(
        text,
        "create or replace function moneytrack.spc001_user_bootstrap_v1(",
        "comment on function moneytrack.spc001_user_bootstrap_v1",
    )

    require(
        "bootstrap_finance_space_output_conflicts_disambiguated",
        "returns table (\n    space_id bigint" in finance
        and "on conflict on constraint space_financial_settings_pkey do nothing" in finance
        and "on conflict on constraint space_default_accounts_pkey do update" in finance
        and finance.count("on conflict do nothing;") >= 2
        and "on conflict (space_id" not in finance.lower(),
    )

    require(
        "bootstrap_user_output_conflicts_disambiguated",
        "telegram_user_id bigint" in user
        and "user_id bigint" in user
        and "on conflict on constraint app_users_telegram_user_id_key do update" in user
        and "on conflict on constraint user_settings_pkey do update" in user
        and "on conflict (telegram_user_id" not in user.lower()
        and "on conflict (user_id" not in user.lower(),
    )

    require(
        "bootstrap_user_where_user_id_qualified",
        "update moneytrack.user_settings us" in user
        and "where us.user_id = v_user_id" in user
        and "where user_id = v_user_id" not in user,
    )

    require(
        "bootstrap_named_constraints_match_canonical_schema",
        all(x in text for x in (
            "app_users_telegram_user_id_key",
            "user_settings_pkey",
            "space_financial_settings_pkey",
            "space_default_accounts_pkey",
        )),
    )

    print("SPC001_BOOTSTRAP_CONFLICT_SOURCE_GATE=PASS")
    print("RUNTIME_DB_EVIDENCE=NOT_CLAIMED")
    print("DB_MUTATION=NONE")


if __name__ == "__main__":
    main()
