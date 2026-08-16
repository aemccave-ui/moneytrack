#!/usr/bin/env python3
"""SPC-001E1 read-only n8n cutover preflight.

Proves that the already-committed Space tenancy DB is compatible with a complete
set of runtime workflow candidates before any n8n import/publish/unpublish.
Only n8n export:workflow is used against runtime state.

The legacy MiniApp API is a mixed surface: GET /api/v1/i18n and GET /api/v1/me
are canonical user-global survivor routes, while its financial routes are
replaced by the Space-native Financial API. E1 classifies ownership per route,
not per workflow, and builds a deterministic survivor candidate before E2.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "ops/sec001/runtime-manifest.json"
BUILDER = ROOT / "scripts/spc001-build-db-migration.py"
FORENSIC = ROOT / "scripts/spc001-runtime-forensic-v3.py"
AUDIT = ROOT / "scripts/spc001-audit-workflow-tenancy.py"
FIN_GEN = ROOT / "scripts/spc001-generate-financial-api.py"
CONTROL_GEN = ROOT / "scripts/spc001-generate-control-api.py"
SURVIVOR_TRANSFORM = ROOT / "scripts/spc001-transform-global-api-survivor.py"

QUICK_ID = "UX022QuickInput202608"
FINANCIAL_ID = "SPC001FinancialApi202608"
CONTROL_ID = "SPC001ControlApi202608"
SURVIVOR_ID = "7TJ2xQTxLsTydXZc"
SURVIVOR_ROUTES = {
    ("GET", "api/v1/i18n"),
    ("GET", "api/v1/me"),
}


def run(
    cmd: list[str],
    *,
    check: bool = True,
    capture: bool = False,
    cwd: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(
        cmd,
        cwd=cwd or ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def die(message: str) -> None:
    raise SystemExit("SPC001_N8N_CUTOVER_PREFLIGHT=FAIL " + message)


def unwrap(raw):
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, list) and len(raw) == 1 and isinstance(raw[0], dict):
        return raw[0]
    die("expected_one_workflow_object")


def load_one(path: Path) -> dict:
    return unwrap(json.loads(path.read_text(encoding="utf-8")))


def load_many(path: Path) -> list[dict]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        return [raw]
    if isinstance(raw, list) and all(isinstance(x, dict) for x in raw):
        return raw
    die(f"invalid_workflow_export_shape path={path}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def metadata(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key.strip()] = value.strip()
    return result


def routes(workflow: dict) -> set[tuple[str, str]]:
    result: set[tuple[str, str]] = set()
    for node in workflow.get("nodes", []):
        if node.get("type") != "n8n-nodes-base.webhook":
            continue
        params = node.get("parameters") or {}
        path = str(params.get("path") or "").strip().lstrip("/")
        if not path:
            continue
        method = str(params.get("httpMethod") or "GET").strip().upper()
        route = (method, path)
        if route in result:
            die(f"duplicate_route_inside_workflow id={workflow.get('id')} route={route!r}")
        result.add(route)
    return result


def route_json(items: set[tuple[str, str]] | list[tuple[str, str]]) -> list[dict[str, str]]:
    return [
        {"method": method, "path": path}
        for method, path in sorted(items)
    ]


def export_one(container: str, workflow_id: str, out: Path, *, published: bool) -> None:
    remote = f"/tmp/spc001-e1-{workflow_id}.json"
    run(["docker", "exec", container, "rm", "-f", remote], check=False)
    cmd = [
        "docker", "exec", container,
        "n8n", "export:workflow",
        f"--id={workflow_id}",
        f"--output={remote}",
    ]
    if published:
        cmd.append("--published")
    try:
        run(cmd)
        run(["docker", "cp", f"{container}:{remote}", str(out)])
    finally:
        run(["docker", "exec", container, "rm", "-f", remote], check=False)
    actual = str(load_one(out).get("id") or "")
    if actual != workflow_id:
        die(f"export_identity_mismatch expected={workflow_id} actual={actual}")


def export_all_published(container: str, out: Path) -> None:
    help_text = run(
        ["docker", "exec", container, "n8n", "export:workflow", "--help"],
        capture=True,
    ).stdout
    if "--all" not in help_text or "--published" not in help_text:
        die("n8n_export_cli_missing_all_or_published")
    remote = "/tmp/spc001-e1-all-published.json"
    run(["docker", "exec", container, "rm", "-f", remote], check=False)
    try:
        run([
            "docker", "exec", container,
            "n8n", "export:workflow", "--all", "--published",
            f"--output={remote}",
        ])
        run(["docker", "cp", f"{container}:{remote}", str(out)])
    finally:
        run(["docker", "exec", container, "rm", "-f", remote], check=False)
    load_many(out)


def verify_d3(evidence_dir: Path, work: Path) -> tuple[str, str]:
    manifest = evidence_dir / "SHA256SUMS"
    meta_path = evidence_dir / "live-commit-metadata.txt"
    if not manifest.is_file() or not meta_path.is_file():
        die("d3_evidence_missing")
    run(["sha256sum", "-c", "SHA256SUMS"], capture=True, cwd=evidence_dir)
    print("D3_EVIDENCE_HASH_MANIFEST=PASS")
    meta = metadata(meta_path)
    required = {
        "LIVE_DB_MUTATION": "COMMIT_APPLIED",
        "LIVE_POST_MIGRATION_READONLY": "PASS",
        "CLONE_COMMIT_REHEARSAL": "PASS",
        "CLONE_SYNTHETIC_VERIFIERS": "PASS",
        "N8N_SERVICE_RESTART": "PASS",
    }
    bad = {k: (meta.get(k), v) for k, v in required.items() if meta.get(k) != v}
    if bad:
        die("d3_evidence_markers=" + json.dumps(bad, sort_keys=True))

    commit = work / "current-migration-commit.sql"
    rollback = work / "current-migration-rollback.sql"
    run([sys.executable, str(BUILDER), "--output", str(commit), "--final", "commit"])
    run([sys.executable, str(BUILDER), "--output", str(rollback), "--final", "rollback"])
    commit_sha, rollback_sha = sha256(commit), sha256(rollback)
    if meta.get("COMMIT_BUNDLE_SHA256") != commit_sha:
        die(f"d3_commit_program_drift evidence={meta.get('COMMIT_BUNDLE_SHA256')} current={commit_sha}")
    if meta.get("ROLLBACK_BUNDLE_SHA256") != rollback_sha:
        die(f"d3_rollback_program_drift evidence={meta.get('ROLLBACK_BUNDLE_SHA256')} current={rollback_sha}")
    print(f"D3_COMMIT_BUNDLE_IDENTITY=PASS sha256={commit_sha}")
    print(f"D3_ROLLBACK_BUNDLE_IDENTITY=PASS sha256={rollback_sha}")
    return commit_sha, rollback_sha


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--expected-head", required=True)
    ap.add_argument("--db-commit-evidence-dir", type=Path, required=True)
    ap.add_argument("--output-dir", type=Path, required=True)
    ap.add_argument("--n8n-container", default="n8n")
    args = ap.parse_args()

    if run(["git", "status", "--porcelain"], capture=True).stdout.strip():
        die("source_checkout_not_clean")
    head = run(["git", "rev-parse", "HEAD"], capture=True).stdout.strip()
    if head != args.expected_head:
        die(f"head_mismatch expected={args.expected_head} actual={head}")

    out = args.output_dir.resolve()
    if out == ROOT or ROOT in out.parents:
        die("output_dir_must_not_be_repo")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    forensic = out / "forensic"
    legacy_dir = out / "legacy-api-published"
    legacy_dir.mkdir()

    evidence_dir = args.db_commit_evidence_dir.resolve()
    commit_sha, rollback_sha = verify_d3(evidence_dir, out)

    if run([
        "docker", "inspect", "-f", "{{.State.Running}}", args.n8n_container
    ], check=False, capture=True).stdout.strip() != "true":
        die("n8n_not_running")

    run([
        sys.executable, str(FORENSIC),
        "--output-dir", str(forensic),
        "--n8n-container", args.n8n_container,
    ])

    financial = out / "candidate-financial-api.json"
    control = out / "candidate-control-api.json"
    run([sys.executable, str(FIN_GEN), "--output", str(financial)])
    run([sys.executable, str(CONTROL_GEN), "--output", str(control)])
    if str(load_one(financial).get("id")) != FINANCIAL_ID:
        die("financial_candidate_identity")
    if str(load_one(control).get("id")) != CONTROL_ID:
        die("control_candidate_identity")

    runtime_manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    legacy_ids = [x["id"] for x in runtime_manifest["apiWorkflows"] if x["id"] != QUICK_ID]
    if SURVIVOR_ID not in legacy_ids:
        die("global_survivor_workflow_missing_from_runtime_manifest")

    legacy_routes: set[tuple[str, str]] = set()
    workflow_routes: dict[str, set[tuple[str, str]]] = {}
    route_owners: dict[tuple[str, str], set[str]] = {}
    for workflow_id in legacy_ids:
        path = legacy_dir / f"{workflow_id}.json"
        export_one(args.n8n_container, workflow_id, path, published=True)
        owned = routes(load_one(path))
        workflow_routes[workflow_id] = owned
        legacy_routes |= owned
        for route in owned:
            route_owners.setdefault(route, set()).add(workflow_id)

    survivor_owner_errors = {
        f"{method} /{path}": sorted(route_owners.get((method, path), set()))
        for method, path in sorted(SURVIVOR_ROUTES)
        if route_owners.get((method, path), set()) != {SURVIVOR_ID}
    }
    if survivor_owner_errors:
        die("global_survivor_route_ownership=" + json.dumps(survivor_owner_errors, sort_keys=True))
    print(
        "GLOBAL_SURVIVOR_ROUTE_OWNERSHIP=PASS "
        f"workflow={SURVIVOR_ID} routes={len(SURVIVOR_ROUTES)}"
    )

    survivor_candidate = out / "candidate-global-api-survivor.json"
    run([
        sys.executable, str(SURVIVOR_TRANSFORM),
        str(legacy_dir / f"{SURVIVOR_ID}.json"),
        str(survivor_candidate),
    ])
    if routes(load_one(survivor_candidate)) != SURVIVOR_ROUTES:
        die("global_survivor_candidate_route_drift")
    print("GLOBAL_SURVIVOR_CANDIDATE=PASS")

    financial_routes = routes(load_one(financial))
    control_routes = routes(load_one(control))
    legacy_financial_routes = legacy_routes - SURVIVOR_ROUTES

    survivor_overlap = sorted(financial_routes & SURVIVOR_ROUTES)
    if survivor_overlap:
        die("financial_api_claims_global_survivor_routes=" + json.dumps(survivor_overlap))

    missing = sorted(legacy_financial_routes - financial_routes)
    if missing:
        die("legacy_financial_routes_not_covered=" + json.dumps(missing))
    if financial_routes & control_routes:
        die("financial_control_route_overlap=" + json.dumps(sorted(financial_routes & control_routes)))
    print(
        f"LEGACY_FINANCIAL_ROUTE_COVERAGE=PASS legacy_financial_routes={len(legacy_financial_routes)} "
        f"financial_routes={len(financial_routes)}"
    )
    print(f"GLOBAL_SURVIVOR_ROUTE_SEPARATION=PASS survivor_routes={len(SURVIVOR_ROUTES)}")
    print(f"CONTROL_ROUTE_SEPARATION=PASS control_routes={len(control_routes)}")

    retire_ids = sorted(workflow_id for workflow_id in legacy_ids if workflow_id != SURVIVOR_ID)
    for workflow_id in retire_ids:
        unexpected = workflow_routes[workflow_id] & SURVIVOR_ROUTES
        if unexpected:
            die(
                f"retire_workflow_owns_survivor_route id={workflow_id} "
                + json.dumps(sorted(unexpected))
            )
    print(f"LEGACY_FINANCIAL_RETIRE_SET=PASS workflows={len(retire_ids)}")

    all_published = out / "all-published.json"
    export_all_published(args.n8n_container, all_published)
    allowed_financial_owners = set(legacy_ids)
    conflicts: list[tuple[str, str, str]] = []
    for wf in load_many(all_published):
        workflow_id = str(wf.get("id") or "")
        for method, path in routes(wf):
            route = (method, path)
            if route in financial_routes and workflow_id not in allowed_financial_owners:
                conflicts.append((method, path, workflow_id))
            if route in control_routes:
                conflicts.append((method, path, workflow_id))
            if route in SURVIVOR_ROUTES and workflow_id != SURVIVOR_ID:
                conflicts.append((method, path, workflow_id))
    if conflicts:
        die("published_route_conflicts=" + json.dumps(sorted(conflicts)))
    print("PUBLISHED_ROUTE_CONFLICT_GATE=PASS")

    audit_inputs = [
        forensic / "candidate-quick-input.json",
        forensic / "candidate-text-processor.json",
        forensic / "live-voice-processor.json",
        forensic / "candidate-photo-processor.json",
        forensic / "candidate-bot.json",
        financial,
        control,
        survivor_candidate,
    ]
    for path in audit_inputs:
        if not path.is_file():
            die(f"candidate_missing path={path}")
    audit_cmd = [sys.executable, str(AUDIT), "--reachable-only", *map(str, audit_inputs)]
    audit = run(audit_cmd, check=False)
    if audit.returncode != 0:
        die("candidate_tenancy_audit_failed")
    print("CANDIDATE_TENANCY_AUDIT=PASS workflows=8")

    cutover_plan = out / "cutover-plan.json"
    cutover_plan.write_text(
        json.dumps({
            "contract": "SPC001-E1-cutover-plan-v1",
            "source_head": head,
            "d3_commit_bundle_sha256": commit_sha,
            "d3_rollback_bundle_sha256": rollback_sha,
            "global_survivor": {
                "workflow_id": SURVIVOR_ID,
                "routes": route_json(SURVIVOR_ROUTES),
                "candidate": survivor_candidate.name,
            },
            "legacy_financial_retire_workflow_ids": retire_ids,
            "legacy_financial_routes": route_json(legacy_financial_routes),
            "financial_candidate": {
                "workflow_id": FINANCIAL_ID,
                "routes": route_json(financial_routes),
                "candidate": financial.name,
            },
            "control_candidate": {
                "workflow_id": CONTROL_ID,
                "routes": route_json(control_routes),
                "candidate": control.name,
            },
            "capture_candidates": {
                "quick_input": "forensic/candidate-quick-input.json",
                "text_processor": "forensic/candidate-text-processor.json",
                "voice_processor": "forensic/live-voice-processor.json",
                "photo_processor": "forensic/candidate-photo-processor.json",
                "bot": "forensic/candidate-bot.json",
            },
        }, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("CUTOVER_PLAN=PASS path=cutover-plan.json")

    meta = out / "preflight-metadata.txt"
    meta.write_text(
        "\n".join([
            f"HEAD={head}",
            f"D3_COMMIT_BUNDLE_SHA256={commit_sha}",
            f"D3_ROLLBACK_BUNDLE_SHA256={rollback_sha}",
            f"D3_EVIDENCE_DIR={evidence_dir}",
            f"N8N_CONTAINER={args.n8n_container}",
            f"LEGACY_API_WORKFLOW_COUNT={len(legacy_ids)}",
            f"LEGACY_FINANCIAL_RETIRE_WORKFLOW_COUNT={len(retire_ids)}",
            f"LEGACY_FINANCIAL_ROUTE_COUNT={len(legacy_financial_routes)}",
            f"GLOBAL_SURVIVOR_WORKFLOW_ID={SURVIVOR_ID}",
            f"GLOBAL_SURVIVOR_ROUTE_COUNT={len(SURVIVOR_ROUTES)}",
            f"FINANCIAL_CANDIDATE_ROUTE_COUNT={len(financial_routes)}",
            f"CONTROL_CANDIDATE_ROUTE_COUNT={len(control_routes)}",
            "DB_MUTATION=NONE",
            "N8N_IMPORT=NONE",
            "N8N_PUBLISH=NONE",
            "N8N_UNPUBLISH=NONE",
            "PREVIEW_MUTATION=NONE",
            "PRODUCTION_FRONTEND_MUTATION=NONE",
            "SPC001_N8N_CUTOVER_PREFLIGHT=PASS",
        ]) + "\n",
        encoding="utf-8",
    )

    manifest_path = out / "SHA256SUMS"
    files = sorted(p for p in out.rglob("*") if p.is_file() and p != manifest_path)
    manifest_path.write_text(
        "".join(f"{sha256(p)}  {p.relative_to(out)}\n" for p in files),
        encoding="utf-8",
    )
    print(f"EVIDENCE_DIR={out}")
    print("DB_MUTATION=NONE")
    print("N8N_IMPORT=NONE")
    print("N8N_PUBLISH=NONE")
    print("N8N_UNPUBLISH=NONE")
    print("PREVIEW_MUTATION=NONE")
    print("PRODUCTION_FRONTEND_MUTATION=NONE")
    print("SPC001_N8N_CUTOVER_PREFLIGHT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
