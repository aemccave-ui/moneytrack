#!/usr/bin/env python3
"""Static fail-closed checks for SPC-001 migration repair PL/pgSQL blocks."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPAIR = ROOT / "db" / "domain" / "SPC-001" / "309_migration_legacy_reference_repair.sql"


def fail(message: str) -> None:
    raise SystemExit(f"SPC001_REPAIR_SQL_STATIC_GATE=FAIL {message}")


def main() -> None:
    text = REPAIR.read_text(encoding="utf-8")
    blocks = re.findall(
        r"do\s+\$(?P<tag>[A-Za-z0-9_]+)\$(?P<body>.*?)\$(?P=tag)\$\s*;",
        text,
        flags=re.I | re.S,
    )
    if not blocks:
        fail("no_do_blocks")

    checked = 0
    for tag, body in blocks:
        record_vars = set(re.findall(r"(?mi)^\s*([A-Za-z_][A-Za-z0-9_]*)\s+record\s*;", body))
        if not record_vars:
            continue
        checked += 1
        table_aliases = set(
            re.findall(
                r"(?i)\b(?:from|join)\s+(?:moneytrack\.)?[A-Za-z_][A-Za-z0-9_]*"
                r"(?:\s+as)?\s+([A-Za-z_][A-Za-z0-9_]*)",
                body,
            )
        )
        collisions = sorted(record_vars & table_aliases)
        if collisions:
            fail(f"record_table_alias_collision block={tag} aliases={','.join(collisions)}")

    if checked < 2:
        fail(f"unexpected_record_block_count={checked}")

    category_match = re.search(
        r"do\s+\$repair_category_paths\$(.*?)\$repair_category_paths\$\s*;",
        text,
        flags=re.I | re.S,
    )
    if not category_match:
        fail("category_repair_block_missing")
    category = category_match.group(1)
    if "join moneytrack.receipts receipt_src on receipt_src.id=ri.receipt_id" not in category:
        fail("category_receipt_alias_not_explicit")

    print(f"repair_record_alias_collision_free=PASS blocks={checked}")
    print("SPC001_REPAIR_SQL_STATIC_GATE=PASS")


if __name__ == "__main__":
    main()
