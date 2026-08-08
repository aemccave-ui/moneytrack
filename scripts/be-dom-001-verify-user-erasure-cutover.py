#!/usr/bin/env python3
"""Verify BE-DOM-001 Apply Delete Me candidate is structurally isolated and backend-owned."""

import argparse
import copy
import json
import re
from pathlib import Path

WORKFLOW_ID = "DER2Lc3dT2afyQhy"
NODE_NAME = "Apply Delete Me"
DIRECT_MUTATION = re.compile(
    r"\b(insert\s+into|update|delete\s+from)\s+moneytrack\.",
    re.I | re.S,
)


def load(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        if len(data) != 1:
            raise SystemExit(f"expected one workflow in {path}, found {len(data)}")
        return data[0]
    if isinstance(data, dict):
        return data
    raise SystemExit(f"unsupported n8n export shape in {path}")


def nodes(wf):
    out = {}
    for n in wf.get("nodes", []):
        name = n.get("name")
        if name in out:
            raise SystemExit(f"duplicate node name {name!r}")
        out[name] = n
    return out


def normalized(wf):
    x = copy.deepcopy(wf)
    matches = [n for n in x.get("nodes", []) if n.get("name") == NODE_NAME]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {NODE_NAME!r} node")
    matches[0].setdefault("parameters", {})["query"] = "__TARGET_QUERY__"
    return x


def require(cond, msg):
    if not cond:
        raise SystemExit("FAIL: " + msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("candidate")
    args = ap.parse_args()

    before = load(Path(args.before))
    after = load(Path(args.candidate))

    require(before.get("id") == after.get("id"), "workflow id changed")
    require(before.get("name") == after.get("name"), "workflow name changed")
    require(after.get("id") == WORKFLOW_ID or after.get("name") == "MoneyTrack", "unexpected workflow")
    require(normalized(before) == normalized(after), "candidate changed structure or non-target content")

    bnodes = nodes(before)
    anodes = nodes(after)
    require(NODE_NAME in anodes, "Apply Delete Me node missing")

    sql = anodes[NODE_NAME].get("parameters", {}).get("query", "")
    require("moneytrack.user_delete_me_v1(" in sql, "backend user_delete_me_v1 call missing")
    require("select d.status" in sql.lower(), "legacy status-only output contract not preserved")
    require(not DIRECT_MUTATION.search(sql), "Apply Delete Me still contains direct moneytrack mutation SQL")

    changed = [name for name in bnodes if bnodes[name] != anodes.get(name)]
    require(changed == [NODE_NAME] or set(changed) == {NODE_NAME}, f"unexpected changed nodes: {changed}")

    print(f"workflow_id={after.get('id')}")
    print("scope=user-erasure")
    print("structural_isolation=PASS")
    print("direct_moneytrack_mutation_bypass=ABSENT_IN_TARGET")
    print("status_contract=PASS")
    print("status=PASS")


if __name__ == "__main__":
    main()
