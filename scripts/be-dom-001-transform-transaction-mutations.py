#!/usr/bin/env python3
"""BE-DOM-001: transform active n8n workflow exports to canonical transaction mutation calls.

Supported workflows:
- MoneyTrack (DER2Lc3dT2afyQhy): command setaccount, delete last
- MoneyTrack MiniApp Delete Transaction (MTxDel7Qp2Vn9Kc4): Delete Transaction

Input/output are n8n JSON exports (normally a one-element JSON array).
No network or runtime mutation is performed by this script.
"""

import argparse
import copy
import json
from pathlib import Path

MAIN_ID = "DER2Lc3dT2afyQhy"
MINI_DELETE_ID = "MTxDel7Qp2Vn9Kc4"

SETACCOUNT_SQL = r"""with input_data as (
    select
        {{ $json.transaction_id || "null" }}::bigint as transaction_id,
        '{{ String($json.account_hint || "").replace(/'/g, "''") }}'::text as account_hint
),
user_row as (
    select {{ $('Get user context').first().json.user_id }}::bigint as user_id
),
target_tx as (
    select
        t.id,
        t.currency_original
    from moneytrack.transactions t
    join user_row u on u.user_id = t.user_id
    cross join input_data i
    where t.id = i.transaction_id
),
matched_account as (
    select
        a.id,
        a.name,
        a.code
    from moneytrack.accounts a
    join user_row u on u.user_id = a.user_id
    join target_tx tx on upper(a.currency_code) = upper(tx.currency_original)
    cross join input_data i
    where i.account_hint <> ''
      and coalesce(a.is_active, true) = true
      and (
          lower(a.code) = lower(i.account_hint)
          or lower(a.name) = lower(i.account_hint)
      )
    order by a.id
    limit 1
),
updated as (
    select c.*
    from user_row ur
    cross join input_data i
    join target_tx tx on true
    join matched_account ma on true
    cross join lateral moneytrack.finance_update_transaction_account_v1(
        ur.user_id,
        tx.id,
        ma.id
    ) c
)
select
    i.transaction_id,
    i.account_hint,
    u.id,
    u.account_name as name,
    u.account_code as code,
    case
        when i.transaction_id is null then 'invalid_command'
        when i.account_hint = '' then 'invalid_command'
        when u.id is null then 'not_found'
        else u.status
    end as status
from input_data i
left join updated u on true;"""

DELETE_LAST_SQL = r"""select
    d.transaction_id as id,
    d.description,
    d.amount_original,
    d.currency_original,
    d.transaction_date
from moneytrack.finance_delete_transaction_v1(
    {{ $('Get user context').first().json.user_id }}::bigint,
    {{ $json.transaction_id || "null" }}::bigint
) d
where d.deleted = true;"""

MINI_DELETE_SQL = r"""with user_ctx as (
    select u.id as user_id
    from moneytrack.app_users u
    where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
    limit 1
),
delete_result as (
    select d.*
    from user_ctx uc
    cross join lateral moneytrack.finance_delete_transaction_v1(
        uc.user_id,
        {{ $json.transaction_id }}::bigint
    ) d
),
deleted_tx as (
    select *
    from delete_result
    where deleted = true
)
select
    exists(select 1 from user_ctx) as user_found,
    exists(select 1 from deleted_tx) as deleted,
    (select transaction_id from deleted_tx limit 1) as id,
    (select description from deleted_tx limit 1) as description,
    (select amount_original from deleted_tx limit 1) as amount_original,
    (select currency_original from deleted_tx limit 1) as currency_original,
    (select transaction_date from deleted_tx limit 1) as transaction_date;"""


def load_export(path: Path):
    with path.open("r", encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, list):
        if len(data) != 1:
            raise SystemExit(f"expected one workflow in export, found {len(data)}")
        return data, data[0]
    if isinstance(data, dict):
        return data, data
    raise SystemExit("unsupported n8n export JSON shape")


def node_by_name(workflow, name):
    matches = [n for n in workflow.get("nodes", []) if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one node {name!r}, found {len(matches)}")
    return matches[0]


def set_query(node, query):
    params = node.setdefault("parameters", {})
    if "query" not in params:
        raise SystemExit(f"node {node.get('name')!r} has no parameters.query")
    params["query"] = query


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    data, workflow = load_export(input_path)
    wf_id = workflow.get("id")
    wf_name = workflow.get("name", "")

    if wf_id == MAIN_ID or wf_name == "MoneyTrack":
        targets = {
            "command setaccount": SETACCOUNT_SQL,
            "delete last": DELETE_LAST_SQL,
        }
    elif wf_id == MINI_DELETE_ID or wf_name == "MoneyTrack MiniApp Delete Transaction":
        targets = {
            "Delete Transaction": MINI_DELETE_SQL,
        }
    else:
        raise SystemExit(
            f"unsupported workflow id={wf_id!r} name={wf_name!r}; "
            f"expected {MAIN_ID} or {MINI_DELETE_ID}"
        )

    before = copy.deepcopy(workflow)
    for node_name, query in targets.items():
        set_query(node_by_name(workflow, node_name), query)

    before_nodes = {n.get("name"): n for n in before.get("nodes", [])}
    after_nodes = {n.get("name"): n for n in workflow.get("nodes", [])}
    if before_nodes.keys() != after_nodes.keys():
        raise SystemExit("node set changed unexpectedly")

    for name in before_nodes:
        b = copy.deepcopy(before_nodes[name])
        a = copy.deepcopy(after_nodes[name])
        if name in targets:
            b.setdefault("parameters", {})["query"] = "__TARGET_QUERY__"
            a.setdefault("parameters", {})["query"] = "__TARGET_QUERY__"
        if b != a:
            raise SystemExit(f"non-query mutation detected in node {name!r}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(f"workflow_id={wf_id}")
    print(f"workflow_name={wf_name}")
    print("changed_nodes=" + ",".join(targets.keys()))
    print("status=PASS")


if __name__ == "__main__":
    main()
