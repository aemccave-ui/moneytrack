#!/usr/bin/env python3
"""Read-only verifier for SPC-001F4 Financial API transport correction."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

FINANCIAL_ID = "SPC001FinancialApi202608"


def die(message: str) -> None:
    raise SystemExit("SPC001_F4_FINANCIAL_TRANSPORT_VERIFY=FAIL " + message)


def unwrap(raw):
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list) and len(raw) == 1 and isinstance(raw[0], dict):
        return raw[0]
    die("expected_one_workflow")


def one(path: Path) -> dict:
    return unwrap(json.loads(path.read_text(encoding="utf-8")))


def many(path: Path) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        return [raw]
    if isinstance(raw, list) and all(isinstance(x, dict) for x in raw):
        return raw
    die(f"invalid_workflow_export path={path}")


def canonical(value) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def core(wf: dict) -> str:
    return canonical({
        "id": wf.get("id"),
        "name": wf.get("name"),
        "nodes": wf.get("nodes") or [],
        "connections": wf.get("connections") or {},
        "settings": wf.get("settings") or {},
    })


def by_id(path: Path) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for wf in many(path):
        workflow_id = str(wf.get("id") or "")
        if not workflow_id or workflow_id in result:
            die(f"invalid_or_duplicate_workflow_id path={path} id={workflow_id!r}")
        result[workflow_id] = wf
    return result


def route_set(wf: dict) -> set[tuple[str, str]]:
    routes: set[tuple[str, str]] = set()
    for node in wf.get("nodes") or []:
        if node.get("type") != "n8n-nodes-base.webhook":
            continue
        params = node.get("parameters") or {}
        path = str(params.get("path") or "").strip().lstrip("/")
        method = str(params.get("httpMethod") or "GET").strip().upper()
        if path:
            routes.add((method, path))
    return routes


def verify_pre(candidate_path: Path, before_current_path: Path, before_published_path: Path) -> None:
    candidate = one(candidate_path)
    before = one(before_current_path)
    published = by_id(before_published_path)
    if str(candidate.get("id") or "") != FINANCIAL_ID or str(before.get("id") or "") != FINANCIAL_ID:
        die("financial_identity")
    if FINANCIAL_ID not in published:
        die("financial_not_published_before")
    routes = route_set(candidate)
    if len(routes) != 30:
        die(f"financial_candidate_route_count={len(routes)}")
    if core(before) == core(candidate):
        die("financial_candidate_is_already_live")
    print("FINANCIAL_PRE_PATCH_PUBLISHED=PASS")
    print(f"FINANCIAL_CANDIDATE_ROUTE_COUNT=PASS routes={len(routes)}")
    print("FINANCIAL_CANDIDATE_DIFF_REQUIRED=PASS")
    print("SPC001_F4_FINANCIAL_TRANSPORT_PRE_RUNTIME=PASS")


def verify_post(candidate_path: Path, before_published_path: Path, after_current_path: Path, after_published_path: Path) -> None:
    candidate = one(candidate_path)
    after_current = one(after_current_path)
    before_published = by_id(before_published_path)
    after_published = by_id(after_published_path)

    if set(before_published) != set(after_published):
        die(
            "published_id_drift "
            f"missing={sorted(set(before_published)-set(after_published))} "
            f"extra={sorted(set(after_published)-set(before_published))}"
        )
    print(f"PUBLISHED_WORKFLOW_ID_SET_PRESERVED=PASS workflows={len(after_published)}")

    if core(after_current) != core(candidate):
        die("financial_current_core_mismatch")
    print("FINANCIAL_CURRENT_CORE_PARITY=PASS")

    published_financial = after_published.get(FINANCIAL_ID)
    if published_financial is None or core(published_financial) != core(candidate):
        die("financial_published_core_mismatch")
    print("FINANCIAL_PUBLISHED_CORE_PARITY=PASS")

    unrelated = []
    for workflow_id, before in before_published.items():
        if workflow_id == FINANCIAL_ID:
            continue
        after = after_published.get(workflow_id)
        if after is None or core(before) != core(after):
            unrelated.append(workflow_id)
    if unrelated:
        die(f"unrelated_published_core_drift ids={sorted(unrelated)}")
    print(f"UNRELATED_PUBLISHED_WORKFLOWS_UNCHANGED=PASS workflows={len(before_published)-1}")

    financial_routes = route_set(candidate)
    owners: dict[tuple[str, str], list[str]] = {}
    for workflow_id, wf in after_published.items():
        for route in route_set(wf):
            owners.setdefault(route, []).append(workflow_id)
    bad = []
    for route in sorted(financial_routes):
        actual = sorted(owners.get(route, []))
        if actual != [FINANCIAL_ID]:
            bad.append((route[0], route[1], actual))
    if bad:
        die("financial_route_ownership=" + json.dumps(bad, ensure_ascii=False))
    print(f"FINANCIAL_ROUTE_OWNERSHIP=PASS routes={len(financial_routes)}")
    print("SPC001_F4_FINANCIAL_TRANSPORT_POST_RUNTIME=PASS")


def verify_rollback(before_published_path: Path, rollback_published_path: Path) -> None:
    before = by_id(before_published_path)
    rollback = by_id(rollback_published_path)
    if set(before) != set(rollback):
        die("rollback_published_id_drift")
    drift = [workflow_id for workflow_id in sorted(before) if core(before[workflow_id]) != core(rollback[workflow_id])]
    if drift:
        die(f"rollback_published_core_drift ids={drift}")
    print(f"ROLLBACK_PUBLISHED_STATE_PARITY=PASS workflows={len(before)}")
    print("SPC001_F4_FINANCIAL_TRANSPORT_ROLLBACK_VERIFY=PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("pre", "post", "rollback"))
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--before-current", type=Path)
    parser.add_argument("--before-published", type=Path, required=True)
    parser.add_argument("--after-current", type=Path)
    parser.add_argument("--after-published", type=Path)
    parser.add_argument("--rollback-published", type=Path)
    args = parser.parse_args()

    if args.mode == "pre":
        if not args.candidate or not args.before_current:
            die("pre_arguments")
        verify_pre(args.candidate, args.before_current, args.before_published)
    elif args.mode == "post":
        if not args.candidate or not args.after_current or not args.after_published:
            die("post_arguments")
        verify_post(args.candidate, args.before_published, args.after_current, args.after_published)
    else:
        if not args.rollback_published:
            die("rollback_arguments")
        verify_rollback(args.before_published, args.rollback_published)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
