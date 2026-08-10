#!/usr/bin/env python3
"""Generate UX-022 n8n thin-adapter candidates.

Business SQL is prohibited here. PostgreSQL nodes may only SELECT versioned
moneytrack backend/domain functions. Telegram InitData verification is injected
from the canonical API-3 fragment already used by production hardening.
"""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / "scripts/api-3-telegram-initdata-verifier.fragment.js").read_text(encoding="utf-8")
NS = uuid.UUID("ef58d9a6-2179-43d5-a97a-a93bf9262e98")


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def js_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def common_verify(extra: str) -> str:
    return f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const headers = $json.headers || {{}};
const query = $json.query || {{}};
const body = $json.body || {{}};
const initData = headers["x-telegram-init-data"] || headers["X-Telegram-Init-Data"] || query.initData || query.init_data || null;
const auth = moneytrackVerifyTelegramInitData({{
  crypto,
  initData,
  botToken: $env.MONEYTRACK_BOT_TOKEN,
  maxAgeSeconds: $env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,
  maxFutureSkewSeconds: $env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS
}});
if (!auth.ok) return [{{ json: auth }}];
const fail = (code, httpStatus = 400) => [{{ json: {{ ok: false, http_status: httpStatus, error: {{ code }} }} }}];
const parseId = (value, code) => {{
  const raw = String(value ?? "").trim();
  if (!/^\\d+$/.test(raw)) return {{ error: code }};
  return {{ value: Number(raw) }};
}};
const parseIds = (value, code, optional = true) => {{
  if (value === undefined || value === null || value === "") return optional ? {{ value: null }} : {{ value: [] }};
  const list = Array.isArray(value) ? value : String(value).split(",");
  const cleaned = list.map((item) => String(item).trim()).filter(Boolean);
  if (cleaned.some((item) => !/^\\d+$/.test(item))) return {{ error: code }};
  return {{ value: [...new Set(cleaned.map(Number))] }};
}};
const sqlArray = (value) => value === null ? "NULL" : `ARRAY[${{value.join(",")}}]::bigint[]`;
const sqlText = (value) => String(value ?? "").replaceAll("'", "''");
const out = {{ ok: true, telegram_user_id: auth.telegram_user_id, auth_contract_version: auth.auth_contract_version }};
{extra}
return [{{ json: out }}];'''


def verify_transactions() -> str:
    return common_verify('''const account = parseId(query.account_id, "ACCOUNT_ID_INVALID");
if (account.error) return fail(account.error);
const dateFrom = String(query.date_from || "");
const dateTo = String(query.date_to || "");
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(dateFrom) || !/^\\d{4}-\\d{2}-\\d{2}$/.test(dateTo)) return fail("DATE_INVALID");
const selected = parseIds(query.selected_account_ids, "SELECTED_ACCOUNT_IDS_INVALID");
const income = parseIds(query.income_category_ids, "INCOME_CATEGORY_IDS_INVALID");
const expense = parseIds(query.expense_category_ids, "EXPENSE_CATEGORY_IDS_INVALID");
if (selected.error) return fail(selected.error); if (income.error) return fail(income.error); if (expense.error) return fail(expense.error);
out.account_id = account.value;
out.date_from = dateFrom; out.date_to = dateTo;
out.include_descendants = String(query.include_descendants || "true") !== "false";
out.selected_account_sql = sqlArray(selected.value);
out.income_category_sql = sqlArray(income.value);
out.expense_category_sql = sqlArray(expense.value);''')


def verify_summary() -> str:
    return common_verify('''const dateFrom = String(query.date_from || "");
const dateTo = String(query.date_to || "");
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(dateFrom) || !/^\\d{4}-\\d{2}-\\d{2}$/.test(dateTo)) return fail("DATE_INVALID");
const selected = parseIds(query.selected_account_ids, "SELECTED_ACCOUNT_IDS_INVALID", false);
const income = parseIds(query.income_category_ids, "INCOME_CATEGORY_IDS_INVALID");
const expense = parseIds(query.expense_category_ids, "EXPENSE_CATEGORY_IDS_INVALID");
if (selected.error) return fail(selected.error); if (income.error) return fail(income.error); if (expense.error) return fail(expense.error);
out.date_from = dateFrom; out.date_to = dateTo;
out.selected_account_sql = sqlArray(selected.value);
out.income_category_sql = sqlArray(income.value);
out.expense_category_sql = sqlArray(expense.value);''')


def verify_route(kind: str) -> str:
    snippets = {
        "preset_get": "",
        "preset_create": '''const name = String(body.name || "").trim(); if (!name || name.length > 80) return fail("PRESET_NAME_INVALID");
const accounts = parseIds(body.account_ids, "ACCOUNT_IDS_INVALID", false); const income = parseIds(body.income_category_ids, "INCOME_CATEGORY_IDS_INVALID", false); const expense = parseIds(body.expense_category_ids, "EXPENSE_CATEGORY_IDS_INVALID", false);
if (accounts.error) return fail(accounts.error); if (income.error) return fail(income.error); if (expense.error) return fail(expense.error);
out.name_sql = sqlText(name); out.account_sql = sqlArray(accounts.value); out.income_sql = sqlArray(income.value); out.expense_sql = sqlArray(expense.value);''',
        "preset_rename": '''const id = parseId(body.id, "PRESET_ID_INVALID"); if (id.error) return fail(id.error); const name = String(body.name || "").trim(); if (!name || name.length > 80) return fail("PRESET_NAME_INVALID"); out.preset_id=id.value; out.name_sql=sqlText(name);''',
        "preset_delete": '''const id = parseId(query.id, "PRESET_ID_INVALID"); if (id.error) return fail(id.error); out.preset_id=id.value;''',
        "account_create": '''const name=String(body.name||"").trim(); const currency=String(body.currency_code||"").trim().toUpperCase(); if(!name) return fail("ACCOUNT_NAME_REQUIRED"); if(!/^[A-Z0-9]{3,12}$/.test(currency)) return fail("ACCOUNT_CURRENCY_INVALID"); const parentRaw=body.parent_id; let parent=null; if(parentRaw!==null&&parentRaw!==undefined&&parentRaw!==""){const parsed=parseId(parentRaw,"PARENT_ID_INVALID"); if(parsed.error)return fail(parsed.error); parent=parsed.value;} out.name_sql=sqlText(name); out.type_sql=sqlText(body.account_type||"cash"); out.currency_sql=sqlText(currency); out.parent_sql=parent===null?"NULL":String(parent); out.code_sql=body.code?`'${sqlText(body.code)}'`:"NULL";''',
        "account_edit": '''const id=parseId(body.account_id,"ACCOUNT_ID_INVALID"); if(id.error)return fail(id.error); const name=String(body.name||"").trim(); if(!name)return fail("ACCOUNT_NAME_REQUIRED"); out.account_id=id.value; out.name_sql=sqlText(name); out.type_sql=sqlText(body.account_type||"");''',
        "account_copy": '''const id=parseId(body.account_id,"ACCOUNT_ID_INVALID"); if(id.error)return fail(id.error); out.account_id=id.value;''',
        "account_move": '''const id=parseId(body.account_id,"ACCOUNT_ID_INVALID"); if(id.error)return fail(id.error); let parent=null; if(body.parent_id!==null&&body.parent_id!==undefined&&body.parent_id!==""){const parsed=parseId(body.parent_id,"PARENT_ID_INVALID"); if(parsed.error)return fail(parsed.error); parent=parsed.value;} out.account_id=id.value; out.parent_sql=parent===null?"NULL":String(parent);''',
        "account_archive": '''const id=parseId(body.account_id,"ACCOUNT_ID_INVALID"); if(id.error)return fail(id.error); out.account_id=id.value;''',
        "account_restore": '''const id=parseId(body.account_id,"ACCOUNT_ID_INVALID"); if(id.error)return fail(id.error); out.account_id=id.value;''',
        "account_delete": '''const id=parseId(query.id,"ACCOUNT_ID_INVALID"); if(id.error)return fail(id.error); out.account_id=id.value;''',
        "move_preview": '''const source=parseId(body.source_account_id,"ACCOUNT_ID_INVALID"); const target=parseId(body.target_account_id,"TARGET_ACCOUNT_ID_INVALID"); if(source.error)return fail(source.error); if(target.error)return fail(target.error); out.source_account_id=source.value; out.target_account_id=target.value;''',
        "move_commit": '''const source=parseId(body.source_account_id,"ACCOUNT_ID_INVALID"); const target=parseId(body.target_account_id,"TARGET_ACCOUNT_ID_INVALID"); if(source.error)return fail(source.error); if(target.error)return fail(target.error); out.source_account_id=source.value; out.target_account_id=target.value;''',
        "archived_get": "",
    }
    return common_verify(snippets[kind])


def postgres_node(name: str, query: str, x: int, y: int, credential_id: str, credential_name: str) -> dict:
    return {
        "parameters": {"operation": "executeQuery", "query": query, "options": {}},
        "type": "n8n-nodes-base.postgres",
        "typeVersion": 2.6,
        "position": [x, y],
        "id": uid(name),
        "name": name,
        "credentials": {"postgres": {"id": credential_id, "name": credential_name}},
        "onError": "continueRegularOutput",
    }


def webhook_node(name: str, path: str, method: str, x: int, y: int) -> dict:
    params = {"path": path, "responseMode": "responseNode", "options": {}}
    if method != "GET":
        params["httpMethod"] = method
    return {
        "parameters": params,
        "type": "n8n-nodes-base.webhook",
        "typeVersion": 2.1,
        "position": [x, y],
        "id": uid(name),
        "name": name,
        "webhookId": uid("webhook:" + name),
    }


def code_node(name: str, code: str, x: int, y: int) -> dict:
    return {
        "parameters": {"jsCode": code},
        "type": "n8n-nodes-base.code",
        "typeVersion": 2,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def if_node(name: str, x: int, y: int) -> dict:
    return {
        "parameters": {
            "conditions": {
                "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict", "version": 2},
                "conditions": [{
                    "id": uid(name + ":condition"),
                    "leftValue": "={{ $json.ok }}",
                    "rightValue": "",
                    "operator": {"type": "boolean", "operation": "true", "singleValue": True},
                }],
                "combinator": "and",
            },
            "options": {},
        },
        "type": "n8n-nodes-base.if",
        "typeVersion": 2.2,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def format_node(name: str, shape: str, x: int, y: int) -> dict:
    code = f'''const row = $input.first().json || {{}};
if (row.error) {{
  const message = String(row.error.message || row.error || "DOMAIN_ERROR");
  const match = message.match(/\\b([A-Z][A-Z0-9_]+)\\b/);
  return [{{ json: {{ ok:false, http_status:400, error:{{ code: match ? match[1] : "DOMAIN_ERROR" }} }} }}];
}}
const data = ({shape});
return [{{ json: {{ ok:true, http_status:200, data }} }}];'''
    return code_node(name, code, x, y)


def respond_node(name: str, x: int, y: int) -> dict:
    return {
        "parameters": {
            "respondWith": "json",
            "responseBody": "={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}",
            "options": {"responseCode": "={{ $json.http_status || 200 }}"},
        },
        "type": "n8n-nodes-base.respondToWebhook",
        "typeVersion": 1.4,
        "position": [x, y],
        "id": uid(name),
        "name": name,
    }


def single_route_workflow(workflow_id: str, name: str, route_name: str, path: str, method: str, verify: str, query: str, shape: str, credential_id: str, credential_name: str) -> dict:
    names = {
        "webhook": route_name + " Webhook",
        "verify": route_name + " Verify",
        "if": route_name + " Auth OK",
        "db": route_name + " Backend",
        "format": route_name + " Format",
        "respond": route_name + " Respond",
    }
    nodes = [
        webhook_node(names["webhook"], path, method, -680, 0),
        code_node(names["verify"], verify, -460, 0),
        if_node(names["if"], -240, 0),
        postgres_node(names["db"], query, -20, -80, credential_id, credential_name),
        format_node(names["format"], shape, 200, -80),
        respond_node(names["respond"], 430, 0),
    ]
    connections = {
        names["webhook"]: {"main": [[{"node": names["verify"], "type": "main", "index": 0}]]},
        names["verify"]: {"main": [[{"node": names["if"], "type": "main", "index": 0}]]},
        names["if"]: {"main": [
            [{"node": names["db"], "type": "main", "index": 0}],
            [{"node": names["respond"], "type": "main", "index": 0}],
        ]},
        names["db"]: {"main": [[{"node": names["format"], "type": "main", "index": 0}]]},
        names["format"]: {"main": [[{"node": names["respond"], "type": "main", "index": 0}]]},
    }
    return {"id": workflow_id, "name": name, "nodes": nodes, "connections": connections, "settings": {"executionOrder": "v1"}, "active": False}


def multi_route_workflow(workflow_id: str, name: str, routes: list[dict], credential_id: str, credential_name: str) -> dict:
    nodes: list[dict] = []
    connections: dict = {}
    for index, route in enumerate(routes):
        y = index * 280
        prefix = route["name"]
        names = {key: prefix + " " + suffix for key, suffix in {
            "webhook": "Webhook", "verify": "Verify", "if": "Auth OK",
            "db": "Backend", "format": "Format", "respond": "Respond",
        }.items()}
        nodes.extend([
            webhook_node(names["webhook"], route["path"], route["method"], -680, y),
            code_node(names["verify"], verify_route(route["kind"]), -460, y),
            if_node(names["if"], -240, y),
            postgres_node(names["db"], route["query"], -20, y - 80, credential_id, credential_name),
            format_node(names["format"], route["shape"], 200, y - 80),
            respond_node(names["respond"], 430, y),
        ])
        connections[names["webhook"]] = {"main": [[{"node": names["verify"], "type": "main", "index": 0}]]}
        connections[names["verify"]] = {"main": [[{"node": names["if"], "type": "main", "index": 0}]]}
        connections[names["if"]] = {"main": [
            [{"node": names["db"], "type": "main", "index": 0}],
            [{"node": names["respond"], "type": "main", "index": 0}],
        ]}
        connections[names["db"]] = {"main": [[{"node": names["format"], "type": "main", "index": 0}]]}
        connections[names["format"]] = {"main": [[{"node": names["respond"], "type": "main", "index": 0}]]}
    return {"id": workflow_id, "name": name, "nodes": nodes, "connections": connections, "settings": {"executionOrder": "v1"}, "active": False}


def build(credential_id: str, credential_name: str) -> dict[str, dict]:
    transactions_query = """select * from moneytrack.api_transactions_read_model_v2(
  {{ $json.telegram_user_id }}::bigint,
  {{ $json.account_id }}::bigint,
  '{{ $json.date_from }}'::date,
  '{{ $json.date_to }}'::date,
  {{ $json.include_descendants ? 'true' : 'false' }}::boolean,
  {{ $json.selected_account_sql }},
  {{ $json.income_category_sql }},
  {{ $json.expense_category_sql }}
);"""
    summary_query = """select * from moneytrack.api_accounts_explorer_summary_read_model_v2(
  {{ $json.telegram_user_id }}::bigint,
  {{ $json.selected_account_sql }},
  {{ $json.income_category_sql }},
  {{ $json.expense_category_sql }},
  '{{ $json.date_from }}'::date,
  '{{ $json.date_to }}'::date,
  '{{ $json.date_to }}'::date
);"""
    workflows = {
        "transactions": single_route_workflow(
            "UX022TxApi202608", "MoneyTrack Transactions API", "Transactions", "api/v1/transactions", "GET",
            verify_transactions(), transactions_query,
            "{ user_id:row.user_id, base_currency:row.base_currency, summary_currency:row.summary_currency, summary:{income:row.income,expense:row.expense,result:row.result,transfers:row.transfers,count:row.count}, missing_rate_count:row.missing_rate_count, transactions:row.transactions || [] }",
            credential_id, credential_name,
        ),
        "summary": single_route_workflow(
            "UX022Summary202608", "MoneyTrack Accounts Explorer Summary", "Summary", "api/v1/accounts-explorer-summary", "GET",
            verify_summary(), summary_query,
            "{ user_id:row.user_id, base_currency:row.base_currency, total_base:row.total_base, account_balances:row.account_balances || [], snapshot_missing_rate_count:row.snapshot_missing_rate_count, period_summary:{income:row.period_income,expense:row.period_expense,result:row.period_result,count:row.period_count}, date_from:row.date_from, date_to:row.date_to }",
            credential_id, credential_name,
        ),
    }

    preset_routes = [
        {"name":"Preset GET","kind":"preset_get","path":"api/v1/filter-presets","method":"GET","query":"select * from moneytrack.filter_presets_read_v1({{ $json.telegram_user_id }}::bigint);","shape":"{ presets:row.presets || [] }"},
        {"name":"Preset POST","kind":"preset_create","path":"api/v1/filter-presets","method":"POST","query":"select * from moneytrack.filter_preset_create_v1({{ $json.telegram_user_id }}::bigint,'{{ $json.name_sql }}'::text,{{ $json.account_sql }},{{ $json.income_sql }},{{ $json.expense_sql }});","shape":"{ preset:row.preset }"},
        {"name":"Preset PATCH","kind":"preset_rename","path":"api/v1/filter-presets","method":"PATCH","query":"select * from moneytrack.filter_preset_rename_v1({{ $json.telegram_user_id }}::bigint,{{ $json.preset_id }}::bigint,'{{ $json.name_sql }}'::text);","shape":"{ preset:row.preset }"},
        {"name":"Preset DELETE","kind":"preset_delete","path":"api/v1/filter-presets","method":"DELETE","query":"select * from moneytrack.filter_preset_delete_v1({{ $json.telegram_user_id }}::bigint,{{ $json.preset_id }}::bigint);","shape":"{ deleted_id:row.deleted_id }"},
    ]
    workflows["presets"] = multi_route_workflow("UX022Presets202608", "MoneyTrack Filter Presets", preset_routes, credential_id, credential_name)

    lifecycle_routes = [
        {"name":"Account POST","kind":"account_create","path":"api/v1/accounts","method":"POST","query":"select * from moneytrack.account_create_v1({{ $json.telegram_user_id }}::bigint,'{{ $json.name_sql }}'::text,'{{ $json.type_sql }}'::text,'{{ $json.currency_sql }}'::text,{{ $json.parent_sql }},{{ $json.code_sql }});","shape":"{ account:row.account }"},
        {"name":"Account PATCH","kind":"account_edit","path":"api/v1/accounts","method":"PATCH","query":"select * from moneytrack.account_edit_v1({{ $json.telegram_user_id }}::bigint,{{ $json.account_id }}::bigint,'{{ $json.name_sql }}'::text,'{{ $json.type_sql }}'::text);","shape":"{ account:row.account }"},
        {"name":"Account DELETE","kind":"account_delete","path":"api/v1/accounts","method":"DELETE","query":"select * from moneytrack.account_delete_v1({{ $json.telegram_user_id }}::bigint,{{ $json.account_id }}::bigint);","shape":"{ deleted_id:row.deleted_id, status:row.status }"},
        {"name":"Account Copy","kind":"account_copy","path":"api/v1/accounts/copy","method":"POST","query":"select * from moneytrack.account_copy_v1({{ $json.telegram_user_id }}::bigint,{{ $json.account_id }}::bigint);","shape":"{ account:row.account }"},
        {"name":"Account Move","kind":"account_move","path":"api/v1/accounts/move","method":"POST","query":"select * from moneytrack.account_move_v1({{ $json.telegram_user_id }}::bigint,{{ $json.account_id }}::bigint,{{ $json.parent_sql }});","shape":"{ account_id:row.account_id, previous_parent_id:row.previous_parent_id, parent_id:row.parent_id, status:row.status }"},
        {"name":"Account Archive","kind":"account_archive","path":"api/v1/accounts/archive","method":"POST","query":"select * from moneytrack.account_archive_v1({{ $json.telegram_user_id }}::bigint,{{ $json.account_id }}::bigint);","shape":"{ account_id:row.account_id, status:row.status }"},
        {"name":"Account Restore","kind":"account_restore","path":"api/v1/accounts/restore","method":"POST","query":"select * from moneytrack.account_restore_v1({{ $json.telegram_user_id }}::bigint,{{ $json.account_id }}::bigint);","shape":"{ account_id:row.account_id, status:row.status }"},
        {"name":"Archived GET","kind":"archived_get","path":"api/v1/accounts/archived","method":"GET","query":"select * from moneytrack.accounts_archived_read_v1({{ $json.telegram_user_id }}::bigint);","shape":"{ accounts:row.accounts || [] }"},
        {"name":"Move Preview","kind":"move_preview","path":"api/v1/accounts/move-operations/preview","method":"POST","query":"select * from moneytrack.account_move_operations_preview_v1({{ $json.telegram_user_id }}::bigint,{{ $json.source_account_id }}::bigint,{{ $json.target_account_id }}::bigint);","shape":"{ source_account_id:row.source_account_id,target_account_id:row.target_account_id,currency_code:row.currency_code,operation_count:row.operation_count,transfer_count:row.transfer_count,collapsing_transfer_count:row.collapsing_transfer_count,opening_balance_conflict:row.opening_balance_conflict }"},
        {"name":"Move Commit","kind":"move_commit","path":"api/v1/accounts/move-operations","method":"POST","query":"select * from moneytrack.account_move_operations_v1({{ $json.telegram_user_id }}::bigint,{{ $json.source_account_id }}::bigint,{{ $json.target_account_id }}::bigint);","shape":"{ operation_count:row.operation_count,transfer_count:row.transfer_count,status:row.status }"},
    ]
    workflows["lifecycle"] = multi_route_workflow("UX022AccountLifecycle202608", "MoneyTrack Account Lifecycle", lifecycle_routes, credential_id, credential_name)
    return workflows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--postgres-credential-id", default="tM27zg5m7tREo2ep")
    parser.add_argument("--postgres-credential-name", default="Postgres account")
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for key, workflow in build(args.postgres_credential_id, args.postgres_credential_name).items():
        path = args.out_dir / f"ux022-{key}.candidate.json"
        path.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"{key}={workflow['id']} nodes={len(workflow['nodes'])} path={path}")


if __name__ == "__main__":
    main()
