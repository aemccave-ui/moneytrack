#!/usr/bin/env python3
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
tx_path = root / "workflows/moneytrack-transactions-api-UX022TxApi202608.json"
summary_path = root / "workflows/moneytrack-accounts-explorer-summary-UX022Summary202608.json"


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def query_node(data, name):
    matches = [n for n in data.get("nodes", []) if n.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"PATCH=FAIL node={name} matches={len(matches)}")
    return matches[0]


def replace_once(text, old, new, marker):
    count = text.count(old)
    if count == 0 and new in text:
        print(f"{marker}=ALREADY_APPLIED")
        return text
    if count != 1:
        raise SystemExit(f"PATCH=FAIL marker={marker} matches={count}")
    print(f"{marker}=PATCHED")
    return text.replace(old, new, 1)


tx = load(tx_path)
tx_node = query_node(tx, "Get Account Transactions")
q = tx_node["parameters"]["query"]

old_expense = """        coalesce(
            sum(
                case
                    when transaction_type = 'expense'
                    then amount_base_effective
                    else 0
                end
            ),
            0
        ) as expense,"""
new_expense = """        coalesce(
            sum(
                case
                    when transaction_type in ('expense', 'adjustment')
                    then amount_base_effective
                    else 0
                end
            ),
            0
        ) as expense,"""
q = replace_once(q, old_expense, new_expense, "tx_expense_turnover")

old_result = """        coalesce(
            sum(
                case
                    when transaction_type = 'income'
                    then amount_base_effective
                    else 0
                end
            ),
            0
        )
        -
        coalesce(
            sum(
                case
                    when transaction_type = 'expense'
                    then amount_base_effective
                    else 0
                end
            ),
            0
        )
        +
        coalesce(
            sum(
                case
                    when transaction_type = 'adjustment'
                    then adjustment_base_effective
                    else 0
                end
            ),
            0
        ) as result,"""
new_result = """        coalesce(
            sum(
                case
                    when transaction_type = 'income'
                    then amount_base_effective
                    else 0
                end
            ),
            0
        )
        -
        coalesce(
            sum(
                case
                    when transaction_type in ('expense', 'adjustment')
                    then amount_base_effective
                    else 0
                end
            ),
            0
        ) as result,"""
q = replace_once(q, old_result, new_result, "tx_result_sign")

tx_node["parameters"]["query"] = q
save(tx_path, tx)

summary = load(summary_path)
sm_node = query_node(summary, "Get Explorer Summary")
sq = sm_node["parameters"]["query"]

old_sm_expense = """        coalesce(sum(case when transaction_type = 'expense' then amount_base_effective else 0 end), 0) as expense,"""
new_sm_expense = """        coalesce(sum(case when transaction_type in ('expense', 'adjustment') then amount_base_effective else 0 end), 0) as expense,"""
sq = replace_once(sq, old_sm_expense, new_sm_expense, "summary_expense_turnover")

old_sm_result = """    (ps.income - ps.expense + ps.adjustment) as period_result,"""
new_sm_result = """    (ps.income - ps.expense) as period_result,"""
sq = replace_once(sq, old_sm_result, new_sm_result, "summary_result_sign")

sm_node["parameters"]["query"] = sq
save(summary_path, summary)

tx2 = load(tx_path)
tq = query_node(tx2, "Get Account Transactions")["parameters"]["query"]
sm2 = load(summary_path)
sq2 = query_node(sm2, "Get Explorer Summary")["parameters"]["query"]

checks = {
    "tx_adjustment_in_expense": "when transaction_type in ('expense', 'adjustment')" in tq,
    "summary_adjustment_in_expense": "transaction_type in ('expense', 'adjustment')" in sq2,
    "summary_result_income_minus_expense": "(ps.income - ps.expense) as period_result" in sq2,
    "snapshot_contract_preserved": "snapshot_summary as" in sq2 and "account_balances" in sq2,
}
for name, ok in checks.items():
    print(f"{name}={'PASS' if ok else 'FAIL'}")
if not all(checks.values()):
    raise SystemExit("PATCH=FAIL verification")
print("PATCH=PASS")
