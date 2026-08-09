#!/usr/bin/env python3
import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "DER2Lc3dT2afyQhy"
TARGET = "Webhook moneytrack-test"
DOWNSTREAM = "Normalize Webhook Input"


def load(path):
    return json.load(open(path, encoding="utf-8"))


def dump(obj, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    args = ap.parse_args()

    before = load(args.before)
    if before.get("id") != WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {before.get('id')}")

    matches = [n for n in before.get("nodes", []) if n.get("name") == TARGET]
    if len(matches) != 1:
        raise SystemExit(f"expected one {TARGET!r}, found {len(matches)}")

    target = matches[0]
    params = target.get("parameters") or {}
    if target.get("type") != "n8n-nodes-base.webhook":
        raise SystemExit("target is not a webhook node")
    if str(params.get("httpMethod") or "GET").upper() != "POST":
        raise SystemExit("target method is not POST")
    if str(params.get("path") or "").lstrip("/") != "moneytrack-test":
        raise SystemExit("target path is not moneytrack-test")

    expected_conn = {"main": [[{"node": DOWNSTREAM, "type": "main", "index": 0}]]}
    actual_conn = (before.get("connections") or {}).get(TARGET)
    if actual_conn != expected_conn:
        raise SystemExit(f"unexpected target connection: {actual_conn!r}")

    for source, conn in (before.get("connections") or {}).items():
        if source == TARGET:
            continue
        for lane in (conn or {}).get("main") or []:
            for edge in lane or []:
                if edge.get("node") == TARGET:
                    raise SystemExit(f"unexpected inbound edge to target from {source}")

    after = copy.deepcopy(before)
    after["nodes"] = [n for n in after.get("nodes", []) if n.get("name") != TARGET]
    after.setdefault("connections", {}).pop(TARGET, None)

    dump(after, args.after)
    print(f"removed_node={TARGET}")
    print(f"removed_connection_source={TARGET}")
    print(f"remaining_nodes={len(after.get('nodes', []))}")
    print("API-2C transform PASS")


if __name__ == "__main__":
    main()
