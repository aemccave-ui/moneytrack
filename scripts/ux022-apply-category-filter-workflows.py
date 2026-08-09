#!/usr/bin/env python3
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else '.')
summary_path = root / 'workflows/moneytrack-accounts-explorer-summary-UX022Summary202608.json'
tx_path = root / 'workflows/moneytrack-transactions-api-UX022TxApi202608.json'


def load(path):
    return json.loads(path.read_text(encoding='utf-8'))


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def node(data, name):
    matches = [item for item in data.get('nodes', []) if item.get('name') == name]
    if len(matches) != 1:
        raise SystemExit(f'PATCH=FAIL node={name} matches={len(matches)}')
    return matches[0]


def replace_once(text, old, new, marker):
    count = text.count(old)
    if count == 0 and new in text:
        print(f'{marker}=ALREADY_APPLIED')
        return text
    if count != 1:
        raise SystemExit(f'PATCH=FAIL marker={marker} matches={count}')
    print(f'{marker}=PATCHED')
    return text.replace(old, new, 1)


category_parser = '''\nconst parseCategoryIds = (key, errorCode) => {\n  if (!Object.prototype.hasOwnProperty.call(query, key)) return null;\n  const raw = String(query[key] ?? "").trim();\n  if (!raw) return [];\n  if (!/^\\d+(,\\d+)*$/.test(raw)) {\n    throw new Error(errorCode);\n  }\n  return [...new Set(raw.split(",").map((value) => Number(value)))];\n};\n\nlet incomeCategoryIds;\nlet expenseCategoryIds;\ntry {\n  incomeCategoryIds = parseCategoryIds("income_category_ids", "INCOME_CATEGORY_IDS_INVALID");\n  expenseCategoryIds = parseCategoryIds("expense_category_ids", "EXPENSE_CATEGORY_IDS_INVALID");\n} catch (error) {\n  return fail(400, error.message);\n}\n\nconst categoryPredicate = (ids, transactionTypes) => {\n  if (ids === null) return null;\n  if (!ids.length) return "false";\n  const types = transactionTypes.map((value) => `'${value}'`).join(",");\n  return `(t.transaction_type in (${types}) and t.category_id = any(ARRAY[${ids.join(",")}]::bigint[]))`;\n};\n\nconst incomePredicate = categoryPredicate(incomeCategoryIds, ["income"]);\nconst expensePredicate = categoryPredicate(expenseCategoryIds, ["expense", "adjustment"]);\nconst categoryFilterPredicate = incomePredicate === null && expensePredicate === null\n  ? "true"\n  : `(${incomePredicate ?? "t.transaction_type = 'income'"} or ${expensePredicate ?? "t.transaction_type in ('expense','adjustment')"})`;\n'''


def patch_tx():
    data = load(tx_path)
    validate = node(data, 'Validate Transactions Request')
    js = validate['parameters']['jsCode']
    anchor = 'const includeDescendants = String(query.include_descendants ?? "true").toLowerCase() !== "false";\n'
    js = replace_once(js, anchor, anchor + category_parser, 'tx_category_parser')

    old_return = '''    include_descendants: includeDescendants\n  }\n}];'''
    new_return = '''    include_descendants: includeDescendants,\n    income_category_ids: incomeCategoryIds,\n    expense_category_ids: expenseCategoryIds,\n    category_filter_predicate: categoryFilterPredicate\n  }\n}];'''
    js = replace_once(js, old_return, new_return, 'tx_category_return')
    validate['parameters']['jsCode'] = js

    sql_node = node(data, 'Get Account Transactions')
    q = sql_node['parameters']['query']
    old_where = '''      and t.transaction_date <\n          (\n              '{{ $json.date_to }}'::date\n              + interval '1 day'\n          )\n),\n\nconverted_transactions as ('''
    new_where = '''      and t.transaction_date <\n          (\n              '{{ $json.date_to }}'::date\n              + interval '1 day'\n          )\n      and {{ $json.category_filter_predicate }}\n),\n\nconverted_transactions as ('''
    q = replace_once(q, old_where, new_where, 'tx_category_sql')
    sql_node['parameters']['query'] = q
    save(tx_path, data)


def patch_summary():
    data = load(summary_path)
    validate = node(data, 'Validate Explorer Summary Request')
    js = validate['parameters']['jsCode']
    anchor = 'const excludedIds = rawExcluded ? [...new Set(rawExcluded.split(",").map((value) => Number(value)))] : [];\n'
    js = replace_once(js, anchor, anchor + category_parser, 'summary_category_parser')

    old_return = '''return [{ json: { ok: true, telegram_user_id: user.id, excluded_account_ids: excludedIds, excluded_sql: excludedIds.join(","), date_from: dateFrom, date_to: dateTo } }];'''
    new_return = '''return [{ json: { ok: true, telegram_user_id: user.id, excluded_account_ids: excludedIds, excluded_sql: excludedIds.join(","), income_category_ids: incomeCategoryIds, expense_category_ids: expenseCategoryIds, category_filter_predicate: categoryFilterPredicate, date_from: dateFrom, date_to: dateTo } }];'''
    js = replace_once(js, old_return, new_return, 'summary_category_return')
    validate['parameters']['jsCode'] = js

    sql_node = node(data, 'Get Explorer Summary')
    q = sql_node['parameters']['query']
    old_where = '''    where t.transaction_date >= '{{ $json.date_from }}'::date\n      and t.transaction_date < ('{{ $json.date_to }}'::date + interval '1 day')\n),\nconverted_period_transactions as ('''
    new_where = '''    where t.transaction_date >= '{{ $json.date_from }}'::date\n      and t.transaction_date < ('{{ $json.date_to }}'::date + interval '1 day')\n      and {{ $json.category_filter_predicate }}\n),\nconverted_period_transactions as ('''
    q = replace_once(q, old_where, new_where, 'summary_category_sql')
    sql_node['parameters']['query'] = q
    save(summary_path, data)


def verify():
    tx = load(tx_path)
    tq = node(tx, 'Get Account Transactions')['parameters']['query']
    tv = node(tx, 'Validate Transactions Request')['parameters']['jsCode']
    sm = load(summary_path)
    sq = node(sm, 'Get Explorer Summary')['parameters']['query']
    sv = node(sm, 'Validate Explorer Summary Request')['parameters']['jsCode']
    checks = {
        'tx_filter_query': 'category_filter_predicate' in tv and 'and {{ $json.category_filter_predicate }}' in tq,
        'summary_filter_query': 'category_filter_predicate' in sv and 'and {{ $json.category_filter_predicate }}' in sq,
        'balance_snapshot_unchanged': 'snapshot_summary as' in sq and 'account_balances' in sq,
        'turnover_contract_preserved': "transaction_type in ('expense', 'adjustment')" in tq and '(ps.income - ps.expense) as period_result' in sq,
    }
    for name, ok in checks.items():
        print(f'{name}={"PASS" if ok else "FAIL"}')
    if not all(checks.values()):
        raise SystemExit('PATCH=FAIL verification')


patch_tx()
patch_summary()
verify()
print('PATCH=PASS')
