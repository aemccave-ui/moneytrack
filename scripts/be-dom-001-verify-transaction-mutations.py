#!/usr/bin/env python3
"""BE-DOM-001 verifier for transaction mutation n8n cutover candidates."""

import argparse
import copy
import json
import re
from pathlib import Path

MAIN_ID = "DER2Lc3dT2afyQhy"
MINI_DELETE_ID = "MTxDel7Qp2Vn9Kc4"

DIRECT_TX_UPDATE = re.compile(r"update\s+moneytrack\.transactions\b", re.I | re.S)
DIRECT_TX_DELETE = re.compile(r"delete\s+from\s+moneytrack\.transactions\b", re.I | re.S)


def load_workflow(path: Path):
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, list):
        if len(data) != 1:
            raise SystemExit(f"expected one workflow in {path}, found {len(data)}")
        return data[0]
    if isinstance(data, dict):
        return data
    raise SystemExit(f"unsupported export shape in {path}")


def node_map(workflow):
    result = {}
    for node in workflow.get("nodes", []):
        name = node.get("name")
        if name in result:
            raise SystemExit(f"duplicate node name {name!r}")
        result[name] = node
    return result


def query(node):
    return node.get("parameters", {}).get("query", "")


def normalized_workflow(workflow, targets):
    value = copy.deepcopy(workflow)
    for node in value.get("nodes", []):
        if node.get("name") in targets:
            if "parameters" not in node or "query" not in node["parameters"]:
                raise SystemExit(f"target node {node.get('name')!r} missing parameters.query")
            node["parameters"]["query"] = "__BE_DOM_001_TARGET_QUERY__"
    return value


def require(cond, message):
    if not cond:
        raise SystemExit("FAIL: " + message)


def verify_main(before, after):
    targets = {"command setaccount", "delete last"}
    bnodes = node_map(before)
    anodes = node_map(after)

    require(targets <= bnodes.keys(), "main before export missing target nodes")
    require(targets <= anodes.keys(), "main candidate missing target nodes")
    require(
        normalized_workflow(before, targets) == normalized_workflow(after, targets),
        "main candidate changed structure or non-target content",
    )

    set_sql = query(anodes["command setaccount"])
    delete_sql = query(anodes["delete last"])

    require(
        "moneytrack.finance_update_transaction_account_v1(" in set_sql,
        "command setaccount does not call finance_update_transaction_account_v1",
    )
    require(
        not DIRECT_TX_UPDATE.search(set_sql),
        "command setaccount still directly updates moneytrack.transactions",
    )
    require(
        "u.account_name as name" in set_sql
        and "u.account_code as code" in set_sql
        and "'invalid_command'" in set_sql
        and "'not_found'" in set_sql,
        "command setaccount does not preserve expected adapter result contract",
    )

    require(
        "moneytrack.finance_delete_transaction_v1(" in delete_sql,
        "delete last does not call finance_delete_transaction_v1",
    )
    require(
        not DIRECT_TX_DELETE.search(delete_sql),
        "delete last still directly deletes moneytrack.transactions",
    )
    require(
        "d.transaction_id as id" in delete_sql
        and "where d.deleted = true" in delete_sql,
        "delete last does not preserve legacy deleted-row output shape",
    )

    changed = [name for name in bnodes if bnodes[name] != anodes.get(name)]
    require(set(changed) == targets, f"unexpected changed main nodes: {changed}")


def verify_mini(before, after):
    targets = {"Delete Transaction"}
    bnodes = node_map(before)
    anodes = node_map(after)

    require(targets <= bnodes.keys(), "mini before export missing Delete Transaction")
    require(targets <= anodes.keys(), "mini candidate missing Delete Transaction")
    require(
        normalized_workflow(before, targets) == normalized_workflow(after, targets),
        "mini candidate changed structure or non-target content",
    )

    sql = query(anodes["Delete Transaction"])

    require(
        "moneytrack.finance_delete_transaction_v1(" in sql,
        "MiniApp Delete Transaction does not call finance_delete_transaction_v1",
    )
    require(
        not DIRECT_TX_DELETE.search(sql),
        "MiniApp Delete Transaction still directly deletes moneytrack.transactions",
    )
    require(
        "exists(select 1 from user_ctx) as user_found" in sql
        and "exists(select 1 from deleted_tx) as deleted" in sql
        and "(select transaction_id from deleted_tx limit 1) as id" in sql,
        "MiniApp Delete Transaction does not preserve response contract",
    )

    changed = [name for name in bnodes if bnodes[name] != anodes.get(name)]
    require(set(changed) == targets, f"unexpected changed mini nodes: {changed}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("before")
    parser.add_argument("candidate")
    args = parser.parse_args()

    before = load_workflow(Path(args.before))
    after = load_workflow(Path(args.candidate))

    require(before.get("id") == after.get("id"), "workflow id changed")
    require(before.get("name") == after.get("name"), "workflow name changed")

    wf_id = after.get("id")
    wf_name = after.get("name", "")

    if wf_id == MAIN_ID or wf_name == "MoneyTrack":
        verify_main(before, after)
        scope = "main"
    elif wf_id == MINI_DELETE_ID or wf_name == "MoneyTrack MiniApp Delete Transaction":
        verify_mini(before, after)
        scope = "miniapp-delete"
    else:
        raise SystemExit(f"FAIL: unsupported workflow id={wf_id!r} name={wf_name!r}")

    print(f"workflow_id={wf_id}")
    print(f"scope={scope}")
    print("structural_isolation=PASS")
    print("direct_transaction_mutation_bypass=ABSENT_IN_TARGETS")
    print("status=PASS")


if __name__ == "__main__":
    main()
