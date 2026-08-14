#!/usr/bin/env python3

from pathlib import Path
import re

sql = Path(
    "db/domain/UX-024/030_legacy_source_vocabulary.sql"
).read_text(encoding="utf-8")

match = re.search(
    r"create\s+or\s+replace\s+function\s+moneytrack\.operation_source_kind_v1"
    r".*?"
    r"as\s+\$function\$(.*?)\$function\$;",
    sql,
    flags=re.IGNORECASE | re.DOTALL,
)

if not match:
    raise SystemExit(
        "operation_source_kind_v1_body=FAIL function body not found"
    )

body = match.group(1).lower()

checks = {
    "legacy_telegram_text_maps_to_text":
        "'telegram_text'" in body
        and "'text'::text" in body,

    "legacy_receipt_maps_to_photo_receipt":
        "'receipt'" in body
        and "'photo_receipt'::text" in body,

    "receipt_relation_authoritative":
        "from moneytrack.receipts" in body
        and "r.transaction_id = p_transaction_id" in body,

    "unknown_legacy_not_invented":
        "else null::text" in body,

    "voice_only_from_persisted_source_type":
        "lower(coalesce(t.source_type, '')) = 'voice'" in body,

    "no_description_heuristic":
        "description" not in body,

    "no_datetime_heuristic":
        "transaction_date" not in body,

    "no_pattern_content_heuristic":
        " like " not in body
        and " ilike " not in body,
}

failed = False

for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
    failed |= not ok

if failed:
    raise SystemExit("UX024_LEGACY_SOURCE_GATE=FAIL")

print("UX024_LEGACY_SOURCE_GATE=PASS")
