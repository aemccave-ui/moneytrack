#!/usr/bin/env python3
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import sys
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLASS_A = {
    "api/v1/security/status",
    "api/v1/security/pin/setup",
    "api/v1/security/pin/unlock",
    "api/v1/security/biometric/unlock",
}

def die(msg: str) -> None:
    raise SystemExit("RUNTIME_CANDIDATE_GATE=FAIL " + msg)

def load_module(rel: str, name: str):
    path = ROOT / rel
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die(f"cannot_load={rel}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

TRANS = load_module("scripts/sec001-transform-class-b.py", "sec001_transform_runtime")

def load_export(path: Path) -> dict:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, list):
        if len(raw) != 1:
            die(f"export_count path={path} count={len(raw)}")
        raw = raw[0]
    if not isinstance(raw, dict):
        die(f"export_shape path={path}")
    return raw

def write_export(path: Path, wf: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps([wf], ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

def canonical_hash(value) -> str:
    return hashlib.sha256(
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    ).hexdigest()

def core_hash(wf: dict) -> str:
    return canonical_hash({
        "nodes": wf.get("nodes") or [],
        "connections": wf.get("connections") or {},
        "settings": wf.get("settings") or {},
    })

def node_map(wf: dict) -> dict[str, dict]:
    return {
        n["name"]: n
        for n in wf.get("nodes") or []
        if n.get("name")
    }

def lanes(wf: dict, name: str):
    return (((wf.get("connections") or {}).get(name) or {}).get("main") or [])

def outgoing(wf: dict, name: str) -> list[str]:
    result = []
    for lane in lanes(wf, name):
        for edge in lane:
            if edge.get("node"):
                result.append(edge["node"])
    return result

def reachable(wf: dict, starts: list[str]) -> set[str]:
    q = deque(starts)
    seen = set()
    while q:
        name = q.popleft()
        if name in seen:
            continue
        seen.add(name)
        q.extend(x for x in outgoing(wf, name) if x not in seen)
    return seen

def api_paths(wf: dict) -> list[tuple[str, str]]:
    result = []
    for n in wf.get("nodes") or []:
        if n.get("type") != "n8n-nodes-base.webhook":
            continue
        path = str((n.get("parameters") or {}).get("path") or "").lstrip("/")
        if path.startswith("api/v1/"):
            result.append((n["name"], path))
    return result

def transform_api(wf: dict) -> dict:
    before_nodes = node_map(wf)
    before_connections = copy.deepcopy(wf.get("connections") or {})

    expected_paths = [
        path for _, path in api_paths(wf)
        if path not in CLASS_A
    ]

    auth_gates = set()
    for webhook_name, path in api_paths(wf):
        if path in CLASS_A:
            continue
        verifier = TRANS.find_telegram_verifier(wf, webhook_name)
        auth = TRANS.find_auth_gate(wf, verifier["name"])
        auth_gates.add(auth["name"])

    candidate, protected = TRANS.transform(
        wf,
        "tM27zg5m7tREo2ep",
        "Postgres account",
    )

    if set(protected) != set(expected_paths):
        die(
            f"protected_routes id={wf.get('id')} "
            f"actual={sorted(protected)} expected={sorted(expected_paths)}"
        )

    after_nodes = node_map(candidate)

    added = set(after_nodes) - set(before_nodes)
    removed = set(before_nodes) - set(after_nodes)
    changed = {
        name for name in set(before_nodes) & set(after_nodes)
        if canonical_hash(before_nodes[name]) != canonical_hash(after_nodes[name])
    }

    expected_added = {
        f"SEC001 Unlock {kind} [{path}]"
        for path in expected_paths
        for kind in ("Prepare", "Verify", "Decision", "OK", "Reject")
    }

    if added != expected_added or removed or changed:
        die(
            f"api_node_delta id={wf.get('id')} "
            f"added={sorted(added)} removed={sorted(removed)} changed={sorted(changed)}"
        )

    after_connections = candidate.get("connections") or {}
    common = set(before_connections) & set(after_connections)
    changed_connections = {
        name for name in common
        if canonical_hash(before_connections[name])
        != canonical_hash(after_connections[name])
    }

    if changed_connections != auth_gates:
        die(
            f"api_connection_delta id={wf.get('id')} "
            f"actual={sorted(changed_connections)} expected={sorted(auth_gates)}"
        )

    return candidate

def private_markers_reachable(wf: dict) -> tuple[bool, bool, bool]:
    triggers = [
        n["name"]
        for n in wf.get("nodes") or []
        if n.get("type") == "n8n-nodes-base.telegramTrigger"
    ]
    if not triggers:
        die("bot_no_telegram_trigger")

    nodes = node_map(wf)
    seen = reachable(wf, triggers)
    blob = "\n".join(
        json.dumps(nodes[n], ensure_ascii=False, sort_keys=True).lower()
        for n in sorted(seen)
        if n in nodes
    )
    return tuple(x in blob for x in ("/summary", "/last", "/settings"))

def assert_quick_capture(wf: dict) -> None:
    triggers = [
        n["name"]
        for n in wf.get("nodes") or []
        if n.get("type") == "n8n-nodes-base.telegramTrigger"
    ]
    nodes = node_map(wf)
    seen = reachable(wf, triggers)
    blob = "\n".join(
        json.dumps(nodes[n], ensure_ascii=False, sort_keys=True).lower()
        for n in sorted(seen)
        if n in nodes
    )
    if "photo" not in blob or "voice" not in blob:
        die("bot_quick_capture_photo_voice_missing")
    if not any(x in blob for x in ("message_text", "message.text", "message text")):
        die("bot_quick_capture_text_missing")

def transform_bot(wf: dict) -> dict:
    candidate = copy.deepcopy(wf)
    before_nodes = node_map(wf)

    if private_markers_reachable(wf) != (True, True, True):
        die("bot_expected_private_commands_not_reachable_before_cutover")

    connections = candidate.get("connections") or {}
    main = ((connections.get("Type Input") or {}).get("main") or [])

    if len(main) <= 3:
        die("bot_type_input_command_branch_missing")

    targets = [x.get("node") for x in main[3] if x.get("node")]
    if targets != ["Switch commands"]:
        die(f"bot_command_branch_unexpected targets={targets}")

    main[3] = []

    if set(node_map(candidate)) != set(before_nodes):
        die("bot_node_names_changed")

    changed_nodes = {
        name for name in before_nodes
        if canonical_hash(before_nodes[name])
        != canonical_hash(node_map(candidate)[name])
    }
    if changed_nodes:
        die(f"bot_node_definitions_changed names={sorted(changed_nodes)}")

    before_conn = wf.get("connections") or {}
    after_conn = candidate.get("connections") or {}
    changed_conn = {
        name for name in set(before_conn) | set(after_conn)
        if canonical_hash(before_conn.get(name))
        != canonical_hash(after_conn.get(name))
    }

    if changed_conn != {"Type Input"}:
        die(f"bot_connection_delta actual={sorted(changed_conn)}")

    if private_markers_reachable(candidate) != (False, False, False):
        die("bot_private_commands_still_reachable")

    assert_quick_capture(candidate)
    return candidate

def verify_protected_api(wf: dict) -> None:
    nodes = node_map(wf)
    for webhook_name, path in api_paths(wf):
        if path in CLASS_A:
            continue
        verifier = TRANS.find_telegram_verifier(wf, webhook_name)
        auth = TRANS.find_auth_gate(wf, verifier["name"])
        expected = f"SEC001 Unlock Prepare [{path}]"
        true_lane = lanes(wf, auth["name"])
        actual = [
            x.get("node")
            for x in (true_lane[0] if true_lane else [])
            if x.get("node")
        ]
        if actual != [expected] or expected not in nodes:
            die(f"runtime_unprotected path={path} actual={actual}")

def generate_security() -> dict:
    gen = load_module(
        "scripts/sec001-generate-security-api.py",
        "sec001_security_runtime",
    )
    raw = gen.build("tM27zg5m7tREo2ep", "Postgres account")
    candidate, protected = TRANS.transform(
        raw,
        "tM27zg5m7tREo2ep",
        "Postgres account",
    )
    expected = {
        "api/v1/security/pin/change",
        "api/v1/security/disable",
        "api/v1/security/biometric/enroll",
        "api/v1/security/biometric/revoke",
    }
    if set(protected) != expected:
        die(f"security_protected_routes actual={sorted(protected)}")
    return candidate

def synthetic_bot() -> dict:
    def n(name, typ, text=""):
        return {
            "name": name,
            "type": typ,
            "parameters": {"jsCode": text} if text else {},
        }

    return {
        "id": "bot-test",
        "nodes": [
            n("Telegram Trigger", "n8n-nodes-base.telegramTrigger"),
            n("Type Input", "n8n-nodes-base.switch"),
            n("Photo Capture", "n8n-nodes-base.code", "photo"),
            n("Voice Capture", "n8n-nodes-base.code", "voice"),
            n("Text Capture", "n8n-nodes-base.code", "message_text"),
            n("Switch commands", "n8n-nodes-base.switch",
              "/summary /last /settings"),
        ],
        "connections": {
            "Telegram Trigger": {
                "main": [[{"node": "Type Input", "type": "main", "index": 0}]]
            },
            "Type Input": {
                "main": [
                    [{"node": "Photo Capture", "type": "main", "index": 0}],
                    [{"node": "Voice Capture", "type": "main", "index": 0}],
                    [{"node": "Text Capture", "type": "main", "index": 0}],
                    [{"node": "Switch commands", "type": "main", "index": 0}],
                ]
            },
        },
        "settings": {},
    }

def self_test() -> None:
    quick_gen = load_module(
        "scripts/ux022r3-generate-quick-input-workflow.py",
        "sec001_quick_runtime_test",
    )
    quick = quick_gen.build("test-postgres", "Postgres account")
    quick_after = transform_api(quick)
    verify_protected_api(quick_after)

    bot = synthetic_bot()
    bot_after = transform_bot(bot)
    assert_quick_capture(bot_after)

    overlay = (
        ROOT / "ops/sec001/docker-compose.sec001.yml"
    ).read_text(encoding="utf-8")
    if "MONEYTRACK_PIN_PEPPER" not in overlay:
        die("compose_overlay_missing_pepper")

    apply_src = (
        ROOT / "scripts/sec001-runtime-apply.sh"
    ).read_text(encoding="utf-8")
    for marker in (
        "SEC001_BACKUP_DIR",
        "export:workflow",
        "--published",
        "import:workflow",
        "publish:workflow",
        "compose-interpolation.prod-h.sh",
        "docker-compose.sec001.yml",
    ):
        if marker not in apply_src:
            die(f"apply_marker_missing marker={marker}")

    backup = (
        ROOT / "scripts/prod-h2-backup-now.sh"
    ).read_text(encoding="utf-8")
    if "/root/stack/n8n/docker-compose.sec001.yml" not in backup:
        die("backup_overlay_not_covered")

    print("RUNTIME_CANDIDATE_SOURCE_GATE=PASS")

def build(manifest_path: Path, export_dir: Path, out_dir: Path) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    out_dir.mkdir(parents=True, exist_ok=True)

    for item in manifest["apiWorkflows"]:
        path = export_dir / f"{item['id']}.json"
        wf = load_export(path)

        if wf.get("id") != item["id"]:
            die(f"workflow_id_mismatch path={path}")

        if item.get("coreSha256"):
            actual = core_hash(wf)
            if actual != item["coreSha256"]:
                die(
                    f"core_hash_mismatch id={item['id']} "
                    f"actual={actual} expected={item['coreSha256']}"
                )

        candidate = transform_api(wf)
        write_export(
            out_dir / f"{item['id']}.candidate.json",
            candidate,
        )
        print(
            f"API_CANDIDATE id={item['id']} "
            f"before={len(wf.get('nodes') or [])} "
            f"after={len(candidate.get('nodes') or [])}"
        )

    bot_item = manifest["bot"]
    bot = load_export(export_dir / f"{bot_item['id']}.json")

    actual_bot_hash = core_hash(bot)
    if actual_bot_hash != bot_item["coreSha256"]:
        die(
            f"bot_core_hash_mismatch actual={actual_bot_hash} "
            f"expected={bot_item['coreSha256']}"
        )

    bot_candidate = transform_bot(bot)
    write_export(
        out_dir / f"{bot_item['id']}.candidate.json",
        bot_candidate,
    )

    security = generate_security()
    write_export(
        out_dir / "SEC001SecurityAPI202608.candidate.json",
        security,
    )

    print("RUNTIME_CANDIDATES=PASS")

def verify_applied(
    manifest_path: Path,
    export_dir: Path,
) -> None:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    for item in manifest["apiWorkflows"]:
        wf = load_export(export_dir / f"{item['id']}.json")
        verify_protected_api(wf)

    bot = load_export(
        export_dir / f"{manifest['bot']['id']}.json"
    )

    if private_markers_reachable(bot) != (False, False, False):
        die("runtime_bot_private_commands_reachable")

    assert_quick_capture(bot)

    security = load_export(
        export_dir / "SEC001SecurityAPI202608.json"
    )
    verify_protected_api(security)

    print("SEC001_RUNTIME_GRAPH_VERIFY=PASS")

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--self-test", action="store_true")
    p.add_argument("--manifest", type=Path)
    p.add_argument("--export-dir", type=Path)
    p.add_argument("--out-dir", type=Path)
    p.add_argument("--verify-applied", action="store_true")
    args = p.parse_args()

    if args.self_test:
        self_test()
        return

    if not args.manifest or not args.export_dir:
        die("manifest_and_export_dir_required")

    if args.verify_applied:
        verify_applied(args.manifest, args.export_dir)
        return

    if not args.out_dir:
        die("out_dir_required")

    build(args.manifest, args.export_dir, args.out_dir)

if __name__ == "__main__":
    main()
