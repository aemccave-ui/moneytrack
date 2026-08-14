#!/usr/bin/env python3
"""Fail-closed SPC-001 audit for exported/transformed n8n workflows.

By default every PostgreSQL node is scanned. With ``--reachable-only`` the audit
starts from actual n8n ingress triggers (Telegram/Webhook/Execute Workflow) and
scans only nodes reachable through workflow connections. This is required for the
canonical Bot snapshot because SEC-001 intentionally preserves disconnected
legacy command/report nodes for forensic/rollback while proving they are
unreachable from TelegramTrigger.

If a workflow has no recognized ingress trigger, reachable-only mode fails safe by
scanning every node instead of assuming orphaned nodes are harmless.
"""
from __future__ import annotations

import argparse
from collections import deque
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

INGRESS_TYPES = {
    "n8n-nodes-base.telegramTrigger",
    "n8n-nodes-base.webhook",
    "n8n-nodes-base.executeWorkflowTrigger",
}


def unwrap_many(doc):
    if isinstance(doc, dict):
        return [doc]
    if isinstance(doc, list) and all(isinstance(x, dict) for x in doc):
        return doc
    raise SystemExit("input must be a workflow object or workflow array")


def compact(sql: str) -> str:
    return re.sub(r"\s+", " ", sql).strip()


def lanes(workflow: dict, source: str) -> list[list[dict]]:
    return ((workflow.get("connections") or {}).get(source) or {}).get("main") or []


def reachable_node_names(workflow: dict) -> tuple[set[str], list[str]]:
    starts = [
        str(node.get("name"))
        for node in workflow.get("nodes", [])
        if node.get("name") and node.get("type") in INGRESS_TYPES
    ]
    if not starts:
        return {
            str(node.get("name"))
            for node in workflow.get("nodes", [])
            if node.get("name")
        }, []

    todo = deque(starts)
    seen: set[str] = set()
    while todo:
        name = todo.popleft()
        if name in seen:
            continue
        seen.add(name)
        for lane in lanes(workflow, name):
            for edge in lane:
                target = edge.get("node")
                if target and target not in seen:
                    todo.append(str(target))
    return seen, starts


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
                dynamic = re.sub(r"\buser_id\s*=\s*0\b", "", sql, flags=re.I)
                dynamic = re.sub(r"\b0\s*=\s*user_id\b", "", dynamic, flags=re.I)
                if pattern.search(dynamic):
                    findings.append("financial_user_id_predicate")
                    break

    if "moneytrack.user_default_accounts" in lower and "user_id" in lower:
        findings.append("legacy_user_default_accounts")

    return sorted(set(findings))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reachable-only", action="store_true")
    ap.add_argument("inputs", nargs="+")
    args = ap.parse_args()

    all_findings = []
    workflow_count = 0
    postgres_total = 0
    postgres_scanned = 0

    for raw_path in args.inputs:
        path = Path(raw_path)
        doc = json.loads(path.read_text(encoding="utf-8"))
        for workflow in unwrap_many(doc):
            workflow_count += 1
            workflow_id = str(workflow.get("id") or "<no-id>")
            workflow_name = str(workflow.get("name") or "<no-name>")
            reachable, ingress = reachable_node_names(workflow)
            if args.reachable_only:
                print(
                    "SPC001_TENANCY_AUDIT_REACHABILITY="
                    + json.dumps({
                        "workflow_id": workflow_id,
                        "ingress": ingress,
                        "reachable_nodes": len(reachable),
                        "fallback_scan_all": not bool(ingress),
                    }, ensure_ascii=False, sort_keys=True)
                )

            for node in workflow.get("nodes", []):
                if node.get("type") != "n8n-nodes-base.postgres":
                    continue
                postgres_total += 1
                if args.reachable_only and str(node.get("name") or "") not in reachable:
                    continue
                postgres_scanned += 1
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
    print(f"SPC001_TENANCY_AUDIT_POSTGRES_TOTAL={postgres_total}")
    print(f"SPC001_TENANCY_AUDIT_POSTGRES_SCANNED={postgres_scanned}")
    print(f"SPC001_TENANCY_AUDIT_MODE={'REACHABLE_ONLY' if args.reachable_only else 'ALL_NODES'}")
    if all_findings:
        print("SPC001_TENANCY_AUDIT=FAIL")
        for finding in all_findings:
            print(json.dumps(finding, ensure_ascii=False, sort_keys=True))
        raise SystemExit(1)

    print("SPC001_TENANCY_AUDIT=PASS")


if __name__ == "__main__":
    main()
