#!/usr/bin/env python3
"""SPC-001 read-only runtime forensic launcher with authoritative n8n discovery.

The host can contain several unrelated n8n stacks. This launcher never selects a
container from its name alone. It first prefers the canonical MoneyTrack runtime
container name used by the accepted SEC-001 deployment (``n8n``), but accepts it
only after a read-only export proves that it contains the canonical MoneyTrack
Bot workflow. If that exact-name container is unavailable or does not match, all
running containers are probed with ``n8n --version`` and the same workflow
identity check. Exactly one canonical Bot holder is required.

No workflow is imported, published, activated or changed. Probe exports live only
in /tmp and are deleted immediately. After discovery this script delegates to the
existing ``spc001-runtime-forensic.py`` with an explicit validated container.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
BOT_ID = "DER2Lc3dT2afyQhy"
CANONICAL_CONTAINER_NAME = "n8n"
FORENSIC = ROOT / "scripts" / "spc001-runtime-forensic.py"


def run(cmd: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=ROOT,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def unwrap_one(doc):
    if isinstance(doc, dict):
        return doc
    if isinstance(doc, list) and len(doc) == 1 and isinstance(doc[0], dict):
        return doc[0]
    raise ValueError("expected one workflow object")


def running(container: str) -> bool:
    result = run(
        ["docker", "inspect", "-f", "{{.State.Running}}", container],
        check=False,
        capture=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


def has_n8n_cli(container: str) -> bool:
    result = run(
        ["docker", "exec", container, "n8n", "--version"],
        check=False,
        capture=True,
    )
    return result.returncode == 0


def probe_canonical_bot(container: str) -> tuple[bool, str]:
    """Return (match, diagnostic) without mutating n8n state."""
    token = uuid.uuid4().hex
    container_path = f"/tmp/spc001-discovery-{token}.json"
    with tempfile.TemporaryDirectory(prefix="spc001-n8n-discovery-") as temp_dir:
        host_path = Path(temp_dir) / "bot.json"
        run(["docker", "exec", container, "rm", "-f", container_path], check=False, capture=True)
        try:
            export = run(
                [
                    "docker", "exec", container,
                    "n8n", "export:workflow",
                    f"--id={BOT_ID}",
                    f"--output={container_path}",
                ],
                check=False,
                capture=True,
            )
            if export.returncode != 0:
                tail = " | ".join(export.stdout.strip().splitlines()[-2:])[:240]
                return False, f"bot_export_rc={export.returncode} detail={tail or 'none'}"

            copied = run(
                ["docker", "cp", f"{container}:{container_path}", str(host_path)],
                check=False,
                capture=True,
            )
            if copied.returncode != 0 or not host_path.is_file():
                return False, f"bot_copy_rc={copied.returncode}"

            try:
                workflow = unwrap_one(json.loads(host_path.read_text(encoding="utf-8")))
            except Exception as exc:  # diagnostic only; no secret/output dump
                return False, f"bot_export_parse={type(exc).__name__}"

            actual = str(workflow.get("id") or "")
            if actual != BOT_ID:
                return False, f"bot_id_mismatch={actual or '<empty>'}"
            return True, f"bot_id={BOT_ID}"
        finally:
            run(["docker", "exec", container, "rm", "-f", container_path], check=False, capture=True)


def container_metadata(container: str) -> str:
    result = run(
        ["docker", "inspect", "-f", "{{.Name}}\t{{.Config.Image}}", container],
        check=False,
        capture=True,
    )
    if result.returncode != 0:
        return container
    value = result.stdout.strip().lstrip("/")
    return value.replace("\t", ":") if value else container


def discover(explicit: str | None) -> str:
    if shutil.which("docker") is None:
        raise SystemExit("SPC001_DISCOVERY=FAIL docker_not_found")

    if explicit:
        if not running(explicit):
            raise SystemExit(f"SPC001_DISCOVERY=FAIL explicit_container_not_running container={explicit}")
        if not has_n8n_cli(explicit):
            raise SystemExit(f"SPC001_DISCOVERY=FAIL explicit_container_has_no_n8n_cli container={explicit}")
        match, diagnostic = probe_canonical_bot(explicit)
        if not match:
            raise SystemExit(
                f"SPC001_DISCOVERY=FAIL explicit_container_not_moneytrack container={explicit} {diagnostic}"
            )
        print(f"SPC001_N8N_DISCOVERY=PASS mode=explicit container={container_metadata(explicit)}")
        return explicit

    # Accepted SEC-001 runtime scripts use the exact name `n8n`. Prefer it, but
    # never trust the name without proving the canonical MoneyTrack Bot identity.
    if running(CANONICAL_CONTAINER_NAME) and has_n8n_cli(CANONICAL_CONTAINER_NAME):
        match, diagnostic = probe_canonical_bot(CANONICAL_CONTAINER_NAME)
        print(
            "SPC001_N8N_PROBE="
            f"container={container_metadata(CANONICAL_CONTAINER_NAME)} "
            f"match={'yes' if match else 'no'} {diagnostic}"
        )
        if match:
            print(
                "SPC001_N8N_DISCOVERY=PASS "
                f"mode=canonical_exact_name container={container_metadata(CANONICAL_CONTAINER_NAME)}"
            )
            return CANONICAL_CONTAINER_NAME

    listed = run(
        ["docker", "ps", "--format", "{{.ID}}"],
        capture=True,
    )
    ids = [line.strip() for line in listed.stdout.splitlines() if line.strip()]
    matches: list[str] = []
    diagnostics: list[str] = []

    for container in ids:
        if container == CANONICAL_CONTAINER_NAME:
            continue
        if not has_n8n_cli(container):
            continue
        match, diagnostic = probe_canonical_bot(container)
        metadata = container_metadata(container)
        diagnostics.append(f"{metadata}:match={'yes' if match else 'no'}:{diagnostic}")
        print(
            "SPC001_N8N_PROBE="
            f"container={metadata} match={'yes' if match else 'no'} {diagnostic}"
        )
        if match:
            matches.append(container)

    if not matches:
        detail = "; ".join(diagnostics)[:1200] or "no_container_with_n8n_cli"
        raise SystemExit(f"SPC001_DISCOVERY=FAIL canonical_moneytrack_n8n_not_found probes={detail}")
    if len(matches) > 1:
        detail = ",".join(container_metadata(x) for x in matches)
        raise SystemExit(
            "SPC001_DISCOVERY=FAIL multiple_containers_hold_canonical_bot "
            f"candidates={detail}; rerun with --n8n-container"
        )

    selected = matches[0]
    print(f"SPC001_N8N_DISCOVERY=PASS mode=workflow_identity container={container_metadata(selected)}")
    return selected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="/tmp/moneytrack-spc001-forensic")
    parser.add_argument("--n8n-container", default=None)
    args = parser.parse_args()

    if not FORENSIC.is_file():
        raise SystemExit(f"SPC001_DISCOVERY=FAIL missing_forensic_runner path={FORENSIC}")

    selected = discover(args.n8n_container)
    cmd = [
        sys.executable,
        str(FORENSIC),
        "--output-dir", args.output_dir,
        "--n8n-container", selected,
    ]
    print("SPC001_DISCOVERY_DELEGATE=spc001-runtime-forensic.py")
    return subprocess.run(cmd, cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
