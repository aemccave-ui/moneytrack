#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--presets", type=Path, required=True)
    parser.add_argument("--lifecycle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    presets = load(args.presets)
    lifecycle = load(args.lifecycle)
    if presets.get("id") != "UX022Presets202608":
        raise SystemExit("PRESET_WORKFLOW_ID_MISMATCH")

    existing_names = {node.get("name") for node in presets.get("nodes", [])}
    lifecycle_names = {node.get("name") for node in lifecycle.get("nodes", [])}
    overlap = sorted(existing_names & lifecycle_names)
    if overlap:
        raise SystemExit(f"NODE_NAME_COLLISION={','.join(overlap)}")

    presets["name"] = "MoneyTrack Filter Presets + Account Lifecycle"
    presets.setdefault("nodes", []).extend(lifecycle.get("nodes", []))
    presets.setdefault("connections", {}).update(lifecycle.get("connections", {}))
    presets["active"] = False

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(presets, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"merged_workflow={presets['id']} nodes={len(presets['nodes'])} path={args.output}")


if __name__ == "__main__":
    main()
