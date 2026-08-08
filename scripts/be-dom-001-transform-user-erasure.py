#!/usr/bin/env python3
"""BE-DOM-001: replace MoneyTrack Apply Delete Me SQL with backend user_delete_me_v1.

Transforms an n8n one-workflow JSON export. Only parameters.query of the
'Apply Delete Me' node may change. No network/runtime mutation is performed.
"""

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID = "DER2Lc3dT2afyQhy"
NODE_NAME = "Apply Delete Me"

TARGET_SQL = r"""select d.status
from moneytrack.user_delete_me_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $json.confirmation_code ? "'" + String($json.confirmation_code).replace(/'/g, "''") + "'" : "null" }}::text
) d;"""


def load_export(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, list):
        if len(data) != 1:
            raise SystemExit(f"expected one workflow, found {len(data)}")
        return data, data[0]
    if isinstance(data, dict):
        return data, data
    raise SystemExit("unsupported n8n export JSON shape")


def node_by_name(workflow, name):
    matches = [n for n in workflow.get("nodes", []) if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one node {name!r}, found {len(matches)}")
    return matches[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args = ap.parse_args()

    data, wf = load_export(Path(args.input))
    if wf.get("id") != WORKFLOW_ID and wf.get("name") != "MoneyTrack":
        raise SystemExit(f"unsupported workflow id={wf.get('id')!r} name={wf.get('name')!r}")

    before = copy.deepcopy(wf)
    node = node_by_name(wf, NODE_NAME)
    params = node.setdefault("parameters", {})
    if "query" not in params:
        raise SystemExit("Apply Delete Me has no parameters.query")
    params["query"] = TARGET_SQL

    bnodes = {n.get("name"): n for n in before.get("nodes", [])}
    anodes = {n.get("name"): n for n in wf.get("nodes", [])}
    if bnodes.keys() != anodes.keys():
        raise SystemExit("node set changed unexpectedly")

    for name in bnodes:
        b = copy.deepcopy(bnodes[name])
        a = copy.deepcopy(anodes[name])
        if name == NODE_NAME:
            b.setdefault("parameters", {})["query"] = "__TARGET_QUERY__"
            a.setdefault("parameters", {})["query"] = "__TARGET_QUERY__"
        if b != a:
            raise SystemExit(f"unexpected non-query change in node {name!r}")

    Path(args.output).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"workflow_id={wf.get('id')}")
    print(f"workflow_name={wf.get('name')}")
    print(f"changed_nodes={NODE_NAME}")
    print("status=PASS")


if __name__ == "__main__":
    main()
