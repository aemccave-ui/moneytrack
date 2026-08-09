#!/usr/bin/env python3
import argparse
import copy
import json

TARGET = "Webhook moneytrack-test"


def load(path):
    return json.load(open(path, encoding="utf-8"))


def node_map(wf):
    return {n["name"]: n for n in wf.get("nodes", [])}


def webhook_signatures(wf):
    out = []
    for n in wf.get("nodes", []):
        if n.get("type") != "n8n-nodes-base.webhook":
            continue
        p = n.get("parameters") or {}
        out.append((n.get("name"), str(p.get("httpMethod") or "GET").upper(), str(p.get("path") or "").lstrip("/")))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    args = ap.parse_args()

    before = load(args.before)
    after = load(args.after)

    if before.get("id") != after.get("id") or before.get("name") != after.get("name"):
        raise SystemExit("workflow identity changed")

    b = node_map(before)
    a = node_map(after)
    if TARGET not in b:
        raise SystemExit("target absent before")
    if TARGET in a:
        raise SystemExit("target still present after")
    if set(a) != set(b) - {TARGET}:
        raise SystemExit("unexpected node set change")

    for name, node in a.items():
        if node != b[name]:
            raise SystemExit(f"unexpected node content change: {name}")

    expected_connections = copy.deepcopy(before.get("connections") or {})
    if TARGET not in expected_connections:
        raise SystemExit("target connection source absent before")
    expected_connections.pop(TARGET)
    if (after.get("connections") or {}) != expected_connections:
        raise SystemExit("unexpected connection drift")

    before_hooks = [x for x in webhook_signatures(before) if x[0] != TARGET]
    after_hooks = webhook_signatures(after)
    if before_hooks != after_hooks:
        raise SystemExit("remaining webhook signatures changed")

    print(f"removed_node_only={TARGET} PASS")
    print(f"remaining_nodes_unchanged={len(a)} PASS")
    print("connections_minus_target_only=PASS")
    print("remaining_webhook_signatures=PASS")
    print("API-2C structural removal verifier PASS")


if __name__ == "__main__":
    main()
