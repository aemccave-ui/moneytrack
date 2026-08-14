#!/usr/bin/env python3
"""SPC-001 read-only live n8n tenancy forensic.

This script NEVER imports or activates workflows and NEVER executes SQL against
MoneyTrack. It uses the n8n CLI only for `export:workflow`, writes exports and
transformed candidates under a temporary output directory, then runs the
committed fail-closed workflow SQL tenancy audit.

Purpose: runtime-derived Text/Photo/Voice processor resolver SQL is not stored in
GitHub. We must inspect the live accepted workflow definitions before writing an
exact resolver transform; guessing resolver node names/queries is forbidden.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BOT_ID = "DER2Lc3dT2afyQhy"
QUICK_INPUT_ID = "UX022QuickInput202608"
EXPECTED_TEXT_ID = "f5ioJKyPTupUMV9h"
EXPECTED_PHOTO_ID = "5VC0EcFB21rwTfoI"
PROCESSOR_NODE_NAMES = {
    "text": "Call 'Transaction Processor Text'",
    "voice": "Call 'Transaction Processor Voice'",
    "photo": "Call 'Transaction Processor Photo'",
}


def run(cmd: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(
        cmd,
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def docker_container(explicit: str | None) -> str:
    if explicit:
        return explicit
    if shutil.which("docker") is None:
        raise SystemExit("SPC001_FORENSIC=FAIL docker_not_found")
    result = run(
        ["docker", "ps", "--format", "{{.ID}}\t{{.Image}}\t{{.Names}}"],
        capture=True,
    )
    candidates = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        if "n8n" in line.lower():
            candidates.append((fields[0], fields[1], fields[2]))
    if not candidates:
        raise SystemExit("SPC001_FORENSIC=FAIL running_n8n_container_not_found")
    if len(candidates) > 1:
        details = ", ".join(f"{cid}:{name}:{image}" for cid, image, name in candidates)
        raise SystemExit(
            "SPC001_FORENSIC=FAIL multiple_n8n_containers; "
            f"rerun with --n8n-container; candidates={details}"
        )
    cid, image, name = candidates[0]
    print(f"N8N_CONTAINER={cid} name={name} image={image}")
    return cid


def unwrap(doc: Any) -> dict[str, Any]:
    if isinstance(doc, dict):
        return doc
    if isinstance(doc, list) and len(doc) == 1 and isinstance(doc[0], dict):
        return doc[0]
    raise ValueError("expected one workflow object")


def load_workflow(path: Path) -> dict[str, Any]:
    return unwrap(json.loads(path.read_text(encoding="utf-8")))


def workflow_id_from_parameter(value: Any) -> str | None:
    if isinstance(value, str):
        text = value.strip()
        return text or None
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, dict):
        for key in ("value", "id", "workflowId"):
            if key in value:
                found = workflow_id_from_parameter(value[key])
                if found:
                    return found
    return None


def referenced_workflow_id(workflow: dict[str, Any], node_name: str) -> str:
    matches = [node for node in workflow.get("nodes", []) if node.get("name") == node_name]
    if len(matches) != 1:
        raise SystemExit(
            f"SPC001_FORENSIC=FAIL expected_one_processor_node name={node_name!r} found={len(matches)}"
        )
    node = matches[0]
    if node.get("type") != "n8n-nodes-base.executeWorkflow":
        raise SystemExit(
            f"SPC001_FORENSIC=FAIL processor_node_type_drift name={node_name!r} type={node.get('type')!r}"
        )
    params = node.get("parameters", {})
    candidates = [
        params.get("workflowId"),
        params.get("workflow"),
        params.get("id"),
    ]
    for candidate in candidates:
        found = workflow_id_from_parameter(candidate)
        if found:
            return found
    # Some n8n versions nest the selector. Fail closed unless one plausible ID
    # can be unambiguously recovered from the serialized parameters.
    raw = json.dumps(params, ensure_ascii=False)
    ids = set(re.findall(r'\b[A-Za-z0-9_-]{12,40}\b', raw))
    ids.discard("n8n-nodes-base")
    if len(ids) == 1:
        return next(iter(ids))
    raise SystemExit(
        f"SPC001_FORENSIC=FAIL processor_workflow_id_unresolved name={node_name!r} params={raw[:500]}"
    )


def export_workflow(container: str, workflow_id: str, label: str, out_dir: Path) -> Path:
    container_path = f"/tmp/spc001-{label}.json"
    host_path = out_dir / f"live-{label}.json"
    run(["docker", "exec", container, "rm", "-f", container_path], check=False)
    try:
        run([
            "docker", "exec", container,
            "n8n", "export:workflow",
            f"--id={workflow_id}",
            f"--output={container_path}",
        ])
        run(["docker", "cp", f"{container}:{container_path}", str(host_path)])
    finally:
        run(["docker", "exec", container, "rm", "-f", container_path], check=False)
    workflow = load_workflow(host_path)
    actual = str(workflow.get("id") or "")
    if actual != workflow_id:
        raise SystemExit(
            f"SPC001_FORENSIC=FAIL export_identity_mismatch label={label} expected={workflow_id} actual={actual}"
        )
    print(f"EXPORTED_{label.upper()}={workflow_id} nodes={len(workflow.get('nodes', []))}")
    return host_path


def transform(script: str, source: Path, target: Path) -> None:
    run([sys.executable, str(ROOT / "scripts" / script), str(source), str(target)])
    load_workflow(target)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="/tmp/moneytrack-spc001-forensic")
    parser.add_argument("--n8n-container", default=None)
    args = parser.parse_args()

    out_dir = Path(args.output_dir).resolve()
    if out_dir == ROOT or ROOT in out_dir.parents:
        raise SystemExit("SPC001_FORENSIC=FAIL output_dir_must_not_be_repo")
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if run(["git", "status", "--porcelain"], capture=True).stdout.strip():
        raise SystemExit("SPC001_FORENSIC=FAIL source_checkout_not_clean")
    source_sha = run(["git", "rev-parse", "HEAD"], capture=True).stdout.strip()
    print(f"SOURCE_SHA={source_sha}")
    print("MUTATION_POLICY=READ_ONLY_EXPORT_ONLY")

    container = docker_container(args.n8n_container)

    bot = export_workflow(container, BOT_ID, "bot", out_dir)
    quick = export_workflow(container, QUICK_INPUT_ID, "quick-input", out_dir)
    bot_workflow = load_workflow(bot)

    processor_ids = {
        kind: referenced_workflow_id(bot_workflow, node_name)
        for kind, node_name in PROCESSOR_NODE_NAMES.items()
    }
    for kind, workflow_id in processor_ids.items():
        print(f"PROCESSOR_{kind.upper()}_ID={workflow_id}")

    if processor_ids["text"] != EXPECTED_TEXT_ID:
        raise SystemExit(
            f"SPC001_FORENSIC=FAIL text_processor_drift expected={EXPECTED_TEXT_ID} actual={processor_ids['text']}"
        )
    if processor_ids["photo"] != EXPECTED_PHOTO_ID:
        raise SystemExit(
            f"SPC001_FORENSIC=FAIL photo_processor_drift expected={EXPECTED_PHOTO_ID} actual={processor_ids['photo']}"
        )

    text = export_workflow(container, processor_ids["text"], "text-processor", out_dir)
    voice = export_workflow(container, processor_ids["voice"], "voice-processor", out_dir)
    photo = export_workflow(container, processor_ids["photo"], "photo-processor", out_dir)

    quick_candidate = out_dir / "candidate-quick-input.json"
    text_candidate = out_dir / "candidate-text-processor.json"
    photo_candidate = out_dir / "candidate-photo-processor.json"
    bot_capture = out_dir / "candidate-bot-capture.json"
    bot_candidate = out_dir / "candidate-bot.json"

    transform("spc001-transform-quick-input.py", quick, quick_candidate)
    transform("spc001-transform-text-processor.py", text, text_candidate)
    transform("spc001-transform-photo-processor.py", photo, photo_candidate)
    transform("spc001-transform-bot-capture.py", bot, bot_capture)
    transform("spc001-transform-bot-receipt-category.py", bot_capture, bot_candidate)

    audit_inputs = [quick_candidate, text_candidate, voice, photo_candidate, bot_candidate]
    audit_cmd = [sys.executable, str(ROOT / "scripts" / "spc001-audit-workflow-tenancy.py")]
    audit_cmd.extend(str(path) for path in audit_inputs)
    audit = run(audit_cmd, check=False)

    manifest = out_dir / "SHA256SUMS"
    paths = sorted(p for p in out_dir.glob("*.json") if p.is_file())
    manifest.write_text(
        "".join(f"{sha256(path)}  {path.name}\n" for path in paths),
        encoding="utf-8",
    )
    print(manifest.read_text(encoding="utf-8"), end="")
    print(f"FORENSIC_DIR={out_dir}")
    print("DB_MUTATION=NONE")
    print("N8N_IMPORT=NONE")
    print("N8N_ACTIVATION=NONE")
    print("PREVIEW_MUTATION=NONE")
    print("PRODUCTION_MUTATION=NONE")

    if audit.returncode != 0:
        print("SPC001_RUNTIME_TENANCY_FORENSIC=FAIL")
        print("NEXT=map exact reported resolver nodes to Space-native backend boundaries")
        return audit.returncode

    print("SPC001_RUNTIME_TENANCY_FORENSIC=PASS")
    print("NEXT=prepare controlled migration/reconciliation source")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
