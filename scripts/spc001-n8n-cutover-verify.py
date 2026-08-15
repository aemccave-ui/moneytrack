#!/usr/bin/env python3
"""Deterministic verifier for SPC-001E2 n8n cutover.

The verifier never mutates runtime state. It compares E1 frozen evidence with
fresh exports before cutover and validates candidate parity plus route ownership
after cutover (or published-state parity after metadata rollback).
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

SURVIVOR_ID = "7TJ2xQTxLsTydXZc"
FINANCIAL_ID = "SPC001FinancialApi202608"
CONTROL_ID = "SPC001ControlApi202608"

CAPTURE_FILES = {
    "DER2Lc3dT2afyQhy": ("forensic/live-bot.json", "forensic/candidate-bot.json"),
    "UX022QuickInput202608": ("forensic/live-quick-input.json", "forensic/candidate-quick-input.json"),
    "f5ioJKyPTupUMV9h": ("forensic/live-text-processor.json", "forensic/candidate-text-processor.json"),
    "Td7kvvrtqQK0FTJg": ("forensic/live-voice-processor.json", "forensic/live-voice-processor.json"),
    "5VC0EcFB21rwTfoI": ("forensic/live-photo-processor.json", "forensic/candidate-photo-processor.json"),
}


def die(message: str) -> None:
    raise SystemExit("SPC001_N8N_CUTOVER_VERIFY=FAIL " + message)


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
    result: set[tuple[str, str]] = set()
    for node in wf.get("nodes") or []:
        if node.get("type") != "n8n-nodes-base.webhook":
            continue
        params = node.get("parameters") or {}
        path = str(params.get("path") or "").strip().lstrip("/")
        if not path:
            continue
        method = str(params.get("httpMethod") or "GET").strip().upper()
        result.add((method, path))
    return result


def plan_routes(section: dict) -> set[tuple[str, str]]:
    return {
        (str(item["method"]).upper(), str(item["path"]).lstrip("/"))
        for item in section.get("routes") or []
    }


def compare_all_published(expected_path: Path, actual_path: Path, marker: str) -> None:
    expected, actual = by_id(expected_path), by_id(actual_path)
    if set(expected) != set(actual):
        die(
            f"{marker}_id_drift missing={sorted(set(expected)-set(actual))} "
            f"extra={sorted(set(actual)-set(expected))}"
        )
    drift = [workflow_id for workflow_id in sorted(expected) if core(expected[workflow_id]) != core(actual[workflow_id])]
    if drift:
        die(f"{marker}_core_drift ids={drift}")
    print(f"{marker}=PASS workflows={len(expected)}")


def verify_pre(e1: Path, runtime: Path) -> None:
    compare_all_published(e1 / "all-published.json", runtime / "all-published.json", "E1_PUBLISHED_RUNTIME_DRIFT_GUARD")

    legacy_dir = e1 / "legacy-api-published"
    published_dir = runtime / "published"
    legacy_files = sorted(legacy_dir.glob("*.json"))
    if not legacy_files:
        die("legacy_published_evidence_missing")
    for expected_path in legacy_files:
        workflow_id = expected_path.stem
        actual_path = published_dir / f"{workflow_id}.json"
        if not actual_path.is_file():
            die(f"pre_published_export_missing id={workflow_id}")
        if core(one(expected_path)) != core(one(actual_path)):
            die(f"legacy_published_core_drift id={workflow_id}")
    print(f"E1_LEGACY_PUBLISHED_CORE_GUARD=PASS workflows={len(legacy_files)}")

    current_dir = runtime / "current"
    for workflow_id, (before_rel, _) in CAPTURE_FILES.items():
        expected_path = e1 / before_rel
        actual_path = current_dir / f"{workflow_id}.json"
        if not expected_path.is_file() or not actual_path.is_file():
            die(f"capture_pre_export_missing id={workflow_id}")
        if core(one(expected_path)) != core(one(actual_path)):
            die(f"capture_current_core_drift id={workflow_id}")
    print(f"E1_CAPTURE_CURRENT_CORE_GUARD=PASS workflows={len(CAPTURE_FILES)}")
    print("SPC001_N8N_CUTOVER_PRE_RUNTIME=PASS")


def verify_post(e1: Path, runtime: Path) -> None:
    plan = json.loads((e1 / "cutover-plan.json").read_text(encoding="utf-8"))
    if plan.get("contract") != "SPC001-E1-cutover-plan-v1":
        die("cutover_plan_contract")

    current_dir = runtime / "current"
    expected_current = {
        SURVIVOR_ID: e1 / str(plan["global_survivor"]["candidate"]),
        FINANCIAL_ID: e1 / str(plan["financial_candidate"]["candidate"]),
        CONTROL_ID: e1 / str(plan["control_candidate"]["candidate"]),
    }
    for workflow_id, (_, candidate_rel) in CAPTURE_FILES.items():
        expected_current[workflow_id] = e1 / candidate_rel

    for workflow_id, expected_path in expected_current.items():
        actual_path = current_dir / f"{workflow_id}.json"
        if not expected_path.is_file() or not actual_path.is_file():
            die(f"post_current_export_missing id={workflow_id}")
        if core(one(expected_path)) != core(one(actual_path)):
            die(f"post_candidate_core_mismatch id={workflow_id}")
    print(f"POST_CANDIDATE_CORE_PARITY=PASS workflows={len(expected_current)}")

    published = by_id(runtime / "all-published.json")
    retire = set(map(str, plan.get("legacy_financial_retire_workflow_ids") or []))
    still_active = sorted(retire & set(published))
    if still_active:
        die(f"legacy_retire_still_published ids={still_active}")
    print(f"LEGACY_FINANCIAL_RETIRE_RUNTIME=PASS workflows={len(retire)}")

    financial_routes = plan_routes(plan["financial_candidate"])
    control_routes = plan_routes(plan["control_candidate"])
    survivor_routes = plan_routes(plan["global_survivor"])
    expected_owner: dict[tuple[str, str], str] = {}
    for route in financial_routes:
        expected_owner[route] = FINANCIAL_ID
    for route in control_routes:
        if route in expected_owner:
            die(f"plan_route_overlap route={route}")
        expected_owner[route] = CONTROL_ID
    for route in survivor_routes:
        if route in expected_owner:
            die(f"plan_route_overlap route={route}")
        expected_owner[route] = SURVIVOR_ID

    owners: dict[tuple[str, str], list[str]] = {}
    for workflow_id, wf in published.items():
        for route in route_set(wf):
            owners.setdefault(route, []).append(workflow_id)

    bad = []
    for route, owner in sorted(expected_owner.items()):
        actual = sorted(owners.get(route, []))
        if actual != [owner]:
            bad.append((route[0], route[1], owner, actual))
    if bad:
        die("route_ownership=" + json.dumps(bad, ensure_ascii=False))
    print(
        "POST_ROUTE_OWNERSHIP=PASS "
        f"financial={len(financial_routes)} control={len(control_routes)} survivor={len(survivor_routes)}"
    )

    e1_published = by_id(e1 / "all-published.json")
    allowed_changed = retire | {
        SURVIVOR_ID,
        FINANCIAL_ID,
        CONTROL_ID,
        *CAPTURE_FILES.keys(),
    }
    unrelated_drift = []
    for workflow_id, before in e1_published.items():
        if workflow_id in allowed_changed:
            continue
        after = published.get(workflow_id)
        if after is None or core(before) != core(after):
            unrelated_drift.append(workflow_id)
    if unrelated_drift:
        die(f"unrelated_published_workflow_drift ids={sorted(unrelated_drift)}")
    print("UNRELATED_PUBLISHED_WORKFLOWS_PRESERVED=PASS")
    print("SPC001_N8N_CUTOVER_POST_RUNTIME=PASS")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("pre", "post", "rollback"))
    ap.add_argument("--e1-dir", type=Path, required=True)
    ap.add_argument("--runtime-dir", type=Path, required=True)
    args = ap.parse_args()

    e1 = args.e1_dir.resolve()
    runtime = args.runtime_dir.resolve()
    if args.mode == "pre":
        verify_pre(e1, runtime)
    elif args.mode == "post":
        verify_post(e1, runtime)
    else:
        compare_all_published(
            runtime / "before-all-published.json",
            runtime / "all-published.json",
            "ROLLBACK_PUBLISHED_STATE_PARITY",
        )
        print("SPC001_N8N_CUTOVER_ROLLBACK_VERIFY=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
