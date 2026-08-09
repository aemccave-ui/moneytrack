#!/usr/bin/env python3
import json
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
TX = ROOT / "workflows/moneytrack-transactions-api-UX022TxApi202608.json"
SUMMARY = ROOT / "workflows/moneytrack-accounts-explorer-summary-UX022Summary202608.json"


def load(path):
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def save(path, data):
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def query_node(data, name):
    for node in data.get("nodes", []):
        if node.get("name") == name:
            return node
    raise SystemExit(f"PATCH=FAIL node_missing={name}")


def replace_once(text, old, new, marker):
    count = text.count(old)
    if count == 1:
        print(f"{marker}=PATCH")
        return text.replace(old, new, 1)
    if count == 0 and new in text:
        print(f"{marker}=ALREADY")
        return text
    raise SystemExit(f"PATCH=FAIL marker={marker} matches={count}")


def patch_transactions():
    data = load(TX)
    node = query_node(data, "Get Account Transactions")
    q = node["parameters"]["query"]

    q = replace_once(
        q,
        """            else null\n        end as amount_base_effective\n\n    from filtered_transactions ft""",
        """            else null\n        end as amount_base_effective,\n\n        case\n            when ft.transaction_type <> 'adjustment' then 0\n            when ft.currency_original = ft.base_currency\n                then coalesce(ft.amount_original, 0)\n            when source_rate.usd_rate is not null\n             and base_rate.usd_rate is not null\n             and source_rate.usd_rate <> 0\n                then\n                    coalesce(ft.amount_original, 0)\n                    * base_rate.usd_rate\n                    / source_rate.usd_rate\n            else null\n        end as adjustment_base_effective\n\n    from filtered_transactions ft""",
        "tx_adjustment_conversion",
    )

    q = replace_once(
        q,
        """        ) as expense_original,\n\n        coalesce(\n            sum(\n                case\n                    when transaction_type = 'income'""",
        """        ) as expense_original,\n\n        coalesce(\n            sum(\n                case\n                    when transaction_type = 'adjustment'\n                    then coalesce(amount_original, 0)\n                    else 0\n                end\n            ),\n            0\n        ) as adjustment_original,\n\n        coalesce(\n            sum(\n                case\n                    when transaction_type = 'income'""",
        "tx_adjustment_original",
    )

    q = replace_once(
        q,
        """        ) as result,\n\n        coalesce(\n            sum(\n                case\n                    when transaction_type = 'transfer'""",
        """        )\n        +\n        coalesce(\n            sum(\n                case\n                    when transaction_type = 'adjustment'\n                    then adjustment_base_effective\n                    else 0\n                end\n            ),\n            0\n        ) as result,\n\n        coalesce(\n            sum(\n                case\n                    when transaction_type = 'transfer'""",
        "tx_adjustment_result",
    )

    old_select = """    case\n        when (select count(*) from scope_accounts) = 1\n        then s.income_original\n        else s.income\n    end as income,\n\n    case\n        when (select count(*) from scope_accounts) = 1\n        then s.expense_original\n        else s.expense\n    end as expense,\n\n    case\n        when (select count(*) from scope_accounts) = 1\n        then s.income_original - s.expense_original\n        else s.result\n    end as result,\n\n    s.transfers,\n    s.count,\n    s.missing_rate_count,\n\n    case\n        when (select count(*) from scope_accounts) = 1\n        then (\n            select ra.currency_code\n            from requested_account ra\n            limit 1\n        )\n        else uc.base_currency\n    end as summary_currency,"""
    new_select = """    s.income as income,\n    s.expense as expense,\n    s.result as result,\n\n    s.transfers,\n    s.count,\n    s.missing_rate_count,\n\n    uc.base_currency as summary_currency,"""
    q = replace_once(q, old_select, new_select, "tx_base_currency_summary")

    node["parameters"]["query"] = q
    save(TX, data)


def patch_summary():
    data = load(SUMMARY)
    node = query_node(data, "Get Explorer Summary")
    q = node["parameters"]["query"]

    q = replace_once(
        q,
        """        abs(coalesce(t.amount_original, 0)) as amount_original,\n        coalesce(nullif(t.currency_original, ''), a.currency_code, uc.base_currency) as source_currency,""",
        """        abs(coalesce(t.amount_original, 0)) as amount_original,\n        coalesce(t.amount_original, 0) as signed_amount_original,\n        coalesce(nullif(t.currency_original, ''), a.currency_code, uc.base_currency) as source_currency,""",
        "summary_signed_adjustment_source",
    )

    q = replace_once(
        q,
        """            else null\n        end as amount_base_effective\n    from period_transactions pt""",
        """            else null\n        end as amount_base_effective,\n        case\n            when pt.transaction_type <> 'adjustment' then 0\n            when pt.source_currency = pt.base_currency then pt.signed_amount_original\n            when source_rate.usd_rate is not null and base_rate.usd_rate is not null and source_rate.usd_rate <> 0\n                then pt.signed_amount_original * base_rate.usd_rate / source_rate.usd_rate\n            else null\n        end as adjustment_base_effective\n    from period_transactions pt""",
        "summary_adjustment_conversion",
    )

    q = replace_once(
        q,
        """        coalesce(sum(case when transaction_type = 'expense' then amount_base_effective else 0 end), 0) as expense,\n        count(*) filter (where amount_base_effective is null)::bigint as missing_rate_count""",
        """        coalesce(sum(case when transaction_type = 'expense' then amount_base_effective else 0 end), 0) as expense,\n        coalesce(sum(case when transaction_type = 'adjustment' then adjustment_base_effective else 0 end), 0) as adjustment,\n        count(*) filter (where amount_base_effective is null)::bigint as missing_rate_count""",
        "summary_adjustment_aggregate",
    )

    q = replace_once(
        q,
        """    (ps.income - ps.expense) as period_result,""",
        """    (ps.income - ps.expense + ps.adjustment) as period_result,""",
        "summary_adjustment_result",
    )

    node["parameters"]["query"] = q
    save(SUMMARY, data)


def verify():
    tx = load(TX)
    txq = query_node(tx, "Get Account Transactions")["parameters"]["query"]
    sm = load(SUMMARY)
    smq = query_node(sm, "Get Explorer Summary")["parameters"]["query"]

    checks = {
        "tx_adjustment_base": "adjustment_base_effective" in txq,
        "tx_adjustment_original": "adjustment_original" in txq,
        "tx_base_summary": "uc.base_currency as summary_currency" in txq,
        "summary_signed_adjustment": "signed_amount_original" in smq,
        "summary_adjustment_result": "ps.income - ps.expense + ps.adjustment" in smq,
        "snapshot_unchanged_marker": "snapshot_summary as" in smq and "account_balances" in smq,
    }
    for name, ok in checks.items():
        print(f"{name}={'PASS' if ok else 'FAIL'}")
    if not all(checks.values()):
        raise SystemExit("PATCH=FAIL verification")


patch_transactions()
patch_summary()
verify()
print("PATCH=PASS")
