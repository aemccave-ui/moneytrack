#!/usr/bin/env python3
"""Fail-closed SPC-001 audit for exported/transformed n8n workflows.

This is intentionally conservative. It scans PostgreSQL node SQL after all SPC
transforms and rejects legacy financial ownership/read paths that still scope by
user_id or access legacy receipt classification storage directly. Security/user-
global queries are not financial findings unless they reference financial tables.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

FINANCIAL_TABLES = (
    "moneytrack.accounts",
    "moneytrack.transactions",
    "moneytrack.transfers",
    "moneytrack.receipts",
    "moneytrack.receipt_items",
    "moneytrack.category_catalog",
    "moneytrack.product_catalog",
    "moneytrack.budget_rules",
    "moneytrack.filter_presets",
    "moneytrack.user_default_accounts",
)

LEGACY_FUNCTIONS = (
    "moneytrack.finance_create_sourced_transaction_v1(",
    "moneytrack.finance_create_transaction_v1(",
    "moneytrack.finance_update_transaction_v1(",
    "moneytrack.finance_delete_transaction_v1(",
    "moneytrack.finance_create_transfer_v1(",
    "moneytrack.finance_update_transfer_v1(",
    "moneytrack.receipt_ingest_v1(",
    "moneytrack.receipt_assign_categories_v1(",
    "moneytrack.receipt_set_item_category_v1(",
    "moneytrack.filter_preset_create_v1(",
    "moneytrack.filter_preset_rename_v1(",
    "moneytrack.filter_preset_delete_v1(",
)

SPACE_NATIVE_MARKERS = (
    "_space_v1(",
    "spc001_",
    "capture_create_projection_",
    "capture_receipt_ingest_",
    "receipt_projection_",
    "space_resolve_default_capture_v1(",
    "bot_capture_context_v1(",
)

USER_SCOPE_PATTERNS = (
    re.compile(r"\b(?:[a-z_][a-z0-9_]*\.)?user_id\s*=", re.I),
    re.compile(r"=\s*(?:[a-z_][a-z0-9_]*\.)?user_id\b", re.I),
    re.compile(r"\buser_id\s+in\s*\(", re.I),
)


def unwrap_many(doc):
    if isinstance(doc, dict):
        return [doc]
    if isinstance(doc, list) and all(isinstance(x, dict) for x in doc):
        return doc
    raise SystemExit("input must be a workflow object or workflow array")


def compact(sql: str) -> str:
    return re.sub(r"\s+", " ", sql).strip()


def findings_for_sql(sql: str) -> list[str]:
    lower = sql.lower()
    findings: list[str] = []
    has_financial_table = any(table in lower for table in FINANCIAL_TABLES)

    for fn in LEGACY_FUNCTIONS:
        if fn in lower:
            findings.append(f"legacy_function:{fn[:-1]}")

    if "moneytrack.receipt_items" in lower:
        findings.append("legacy_receipt_items_storage")
    if "moneytrack.receipts" in lower and not any(marker in lower for marker in SPACE_NATIVE_MARKERS):
        findings.append("legacy_receipts_storage")

    if has_financial_table:
        for pattern in USER_SCOPE_PATTERNS:
            if pattern.search(sql):
                # Template sentinel user 0 is GLOBAL_PLATFORM and is allowed only
                # when explicitly constant; dynamic user-owned predicates are not.
                dynamic = re.sub(r"\buser_id\s*=\s*0\b", "", sql, flags=re.I)
                dynamic = re.sub(r"\b0\s*=\s*user_id\b", "", dynamic, flags=re.I)
                if pattern.search(dynamic):
                    findings.append("financial_user_id_predicate")
                    break

    # Explicitly detect the pre-SPC default-account table as financial ownership.
    if "moneytrack.user_default_accounts" in lower and "user_id" in lower:
        findings.append("legacy_user_default_accounts")

    return sorted(set(findings))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+")
    args = ap.parse_args()

    all_findings = []
    workflow_count = 0
    postgres_count = 0

    for raw_path in args.inputs:
        path = Path(raw_path)
        doc = json.loads(path.read_text(encoding="utf-8"))
        for workflow in unwrap_many(doc):
            workflow_count += 1
            workflow_id = str(workflow.get("id") or "<no-id>")
            workflow_name = str(workflow.get("name") or "<no-name>")
            for node in workflow.get("nodes", []):
                if node.get("type") != "n8n-nodes-base.postgres":
                    continue
                postgres_count += 1
                sql = str(node.get("parameters", {}).get("query", ""))
                if not sql:
                    continue
                findings = findings_for_sql(sql)
                if findings:
                    all_findings.append({
                        "file": str(path),
                        "workflow_id": workflow_id,
                        "workflow_name": workflow_name,
                        "node": str(node.get("name") or "<no-name>"),
                        "findings": findings,
                        "sql": compact(sql)[:800],
                    })

    print(f"SPC001_TENANCY_AUDIT_WORKFLOWS={workflow_count}")
    print(f"SPC001_TENANCY_AUDIT_POSTGRES_NODES={postgres_count}")
    if all_findings:
        print("SPC001_TENANCY_AUDIT=FAIL")
        for finding in all_findings:
            print(json.dumps(finding, ensure_ascii=False, sort_keys=True))
        raise SystemExit(1)

    print("SPC001_TENANCY_AUDIT=PASS")


if __name__ == "__main__":
    main()
