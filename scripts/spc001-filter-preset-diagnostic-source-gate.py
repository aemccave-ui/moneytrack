#!/usr/bin/env python3
"""Static source gate for the SPC-001 legacy filter-preset diagnostic."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "db/domain/SPC-001/314_filter_preset_reference_diagnostic.sql"

if not SQL.is_file():
    raise SystemExit("SPC001_FILTER_PRESET_DIAGNOSTIC_SOURCE_GATE=FAIL missing_sql")

text = SQL.read_text(encoding="utf-8")
low = text.lower()

required = (
    "begin transaction read only",
    "filter_account_reference_invalid",
    "filter_category_reference_invalid",
    "filter_template_category_target_not_unique",
    "filter_template_map|refs=",
    "filter_template_ref|preset=",
    "spc001_filter_preset_reference_diagnostic=pass",
    "rollback;",
)
for token in required:
    if token not in low:
        raise SystemExit(f"SPC001_FILTER_PRESET_DIAGNOSTIC_SOURCE_GATE=FAIL missing={token}")

executable = [
    line for line in text.splitlines()
    if line.strip() and not line.lstrip().startswith("--")
]
for line in executable:
    if re.match(r"\s*(insert|update|delete|alter|create|drop|truncate)\b", line, re.I):
        raise SystemExit(
            "SPC001_FILTER_PRESET_DIAGNOSTIC_SOURCE_GATE=FAIL "
            f"mutation_statement={line.strip()}"
        )

print("filter_preset_diagnostic_read_only=PASS")
print("filter_preset_diagnostic_legacy_contract_guarded=PASS")
print("SPC001_FILTER_PRESET_DIAGNOSTIC_SOURCE_GATE=PASS")
print("DB_MUTATION=NONE")
