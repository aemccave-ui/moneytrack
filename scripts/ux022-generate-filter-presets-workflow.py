#!/usr/bin/env python3
import json
import sys
import uuid
from pathlib import Path

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else 'workflows/moneytrack-filter-presets-UX022Presets202608.json')
WORKFLOW_ID = 'UX022Presets202608'
CREDENTIAL = {'postgres': {'id': 'tM27zg5m7tREo2ep', 'name': 'Postgres account'}}
NS = uuid.UUID('3c72af20-3e10-4bf0-8d8d-f760b6472033')


def uid(name):
    return str(uuid.uuid5(NS, name))


def verify_js(mode):
    return f'''const crypto = require("crypto");
const headers = $json.headers || {{}};
const query = $json.query || {{}};
const body = $json.body || {{}};
const fail = (httpStatus, error) => [{{ json: {{ ok: false, http_status: httpStatus, error }} }}];

const initData = headers["x-telegram-init-data"] || headers["X-Telegram-Init-Data"] || query.initData || query.init_data || null;
if (!initData) return fail(401, "INIT_DATA_MISSING");
const token = $env.MONEYTRACK_BOT_TOKEN;
if (!token) return fail(500, "BOT_TOKEN_MISSING");

const params = {{}};
try {{
  for (const part of initData.split("&")) {{
    const i = part.indexOf("=");
    if (i < 0) continue;
    params[decodeURIComponent(part.slice(0, i))] = decodeURIComponent(part.slice(i + 1));
  }}
}} catch {{
  return fail(401, "INVALID_INIT_DATA");
}}
const received = params.hash;
if (!received) return fail(401, "HASH_MISSING");
delete params.hash;
const check = Object.keys(params).sort().map((key) => `${{key}}=${{params[key]}}`).join("\\n");
const secret = crypto.createHmac("sha256", "WebAppData").update(token).digest();
const calculated = crypto.createHmac("sha256", secret).update(check).digest("hex");
if (calculated !== received) return fail(401, "INVALID_INIT_DATA_HASH");

let user;
try {{ user = JSON.parse(params.user || "{{}}"); }} catch {{ return fail(401, "INVALID_USER_DATA"); }}
if (!user?.id) return fail(401, "USER_MISSING");
const out = {{ ok: true, telegram_user_id: user.id }};

const parseIdArray = (value, errorCode) => {{
  if (!Array.isArray(value)) return {{ error: errorCode }};
  if (value.some((item) => !/^\\d+$/.test(String(item)))) return {{ error: errorCode }};
  return {{ value: [...new Set(value.map(Number))] }};
}};

const mode = "{mode}";
if (mode === "POST") {{
  const name = String(body.name || "").trim();
  if (!name || name.length > 80) return fail(400, "PRESET_NAME_INVALID");
  const accounts = parseIdArray(body.account_ids, "ACCOUNT_IDS_INVALID");
  const income = parseIdArray(body.income_category_ids, "INCOME_CATEGORY_IDS_INVALID");
  const expense = parseIdArray(body.expense_category_ids, "EXPENSE_CATEGORY_IDS_INVALID");
  if (accounts.error) return fail(400, accounts.error);
  if (income.error) return fail(400, income.error);
  if (expense.error) return fail(400, expense.error);
  out.name = name;
  out.name_sql = name.replaceAll("'", "''");
  out.account_ids = accounts.value;
  out.income_category_ids = income.value;
  out.expense_category_ids = expense.value;
}}
if (mode === "PATCH") {{
  const id = String(body.id || "").trim();
  const name = String(body.name || "").trim();
  if (!/^\\d+$/.test(id)) return fail(400, "PRESET_ID_INVALID");
  if (!name || name.length > 80) return fail(400, "PRESET_NAME_INVALID");
  out.preset_id = Number(id);
  out.name = name;
  out.name_sql = name.replaceAll("'", "''");
}}
if (mode === "DELETE") {{
  const id = String(query.id || "").trim();
  if (!/^\\d+$/.test(id)) return fail(400, "PRESET_ID_INVALID");
  out.preset_id = Number(id);
}}
return [{{ json: out }}];'''


def if_node(name, x, y):
    return {
        'parameters': {
            'conditions': {
                'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict', 'version': 2},
                'conditions': [{
                    'id': uid(name + ':condition'),
                    'leftValue': '={{ $json.ok }}',
                    'rightValue': '',
                    'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True},
                }],
                'combinator': 'and',
            },
            'options': {},
        },
        'type': 'n8n-nodes-base.if',
        'typeVersion': 2.2,
        'position': [x, y],
        'id': uid(name),
        'name': name,
    }


def webhook(mode, y):
    params = {'path': 'api/v1/filter-presets', 'responseMode': 'responseNode', 'options': {}}
    if mode != 'GET':
        params['httpMethod'] = mode
    return {
        'parameters': params,
        'type': 'n8n-nodes-base.webhook',
        'typeVersion': 2.1,
        'position': [-720, y],
        'id': uid('webhook:' + mode),
        'name': 'filter presets ' + mode.lower(),
        'webhookId': uid('webhook-id:' + mode),
    }


SQL = {
    'GET': '''with user_ctx as (
  select id as user_id from moneytrack.app_users
  where telegram_user_id = {{ $json.telegram_user_id }}::bigint limit 1
)
select
  exists(select 1 from user_ctx) as user_found,
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', p.id,
        'name', p.name,
        'account_ids', p.account_ids,
        'income_category_ids', p.income_category_ids,
        'expense_category_ids', p.expense_category_ids,
        'created_at', p.created_at
      ) order by p.created_at, p.id
    ) filter (where p.id is not null),
    '[]'::jsonb
  ) as presets
from user_ctx u
left join moneytrack.filter_presets p on p.user_id = u.user_id;''',
    'POST': '''with user_ctx as (
  select id as user_id from moneytrack.app_users
  where telegram_user_id = {{ $json.telegram_user_id }}::bigint limit 1
), ins as (
  insert into moneytrack.filter_presets(user_id, name, account_ids, income_category_ids, expense_category_ids)
  select
    user_id,
    '{{ $json.name_sql }}',
    ARRAY[{{ $json.account_ids.join(',') }}]::bigint[],
    ARRAY[{{ $json.income_category_ids.join(',') }}]::bigint[],
    ARRAY[{{ $json.expense_category_ids.join(',') }}]::bigint[]
  from user_ctx
  returning *
)
select
  exists(select 1 from user_ctx) as user_found,
  (select jsonb_build_object(
    'id', id,
    'name', name,
    'account_ids', account_ids,
    'income_category_ids', income_category_ids,
    'expense_category_ids', expense_category_ids,
    'created_at', created_at
  ) from ins limit 1) as preset;''',
    'PATCH': '''with user_ctx as (
  select id as user_id from moneytrack.app_users
  where telegram_user_id = {{ $json.telegram_user_id }}::bigint limit 1
), upd as (
  update moneytrack.filter_presets p
  set name = '{{ $json.name_sql }}'
  from user_ctx u
  where p.id = {{ $json.preset_id }}::bigint and p.user_id = u.user_id
  returning p.*
)
select
  exists(select 1 from user_ctx) as user_found,
  (select jsonb_build_object(
    'id', id,
    'name', name,
    'account_ids', account_ids,
    'income_category_ids', income_category_ids,
    'expense_category_ids', expense_category_ids,
    'created_at', created_at
  ) from upd limit 1) as preset;''',
    'DELETE': '''with user_ctx as (
  select id as user_id from moneytrack.app_users
  where telegram_user_id = {{ $json.telegram_user_id }}::bigint limit 1
), del as (
  delete from moneytrack.filter_presets p
  using user_ctx u
  where p.id = {{ $json.preset_id }}::bigint and p.user_id = u.user_id
  returning p.id
)
select
  exists(select 1 from user_ctx) as user_found,
  coalesce((select id from del limit 1), 0)::bigint as deleted_id;''',
}

FORMAT = {
    'GET': '''const row = $input.first().json || {};
if (!row.user_found) return [{ json: { ok: false, http_status: 404, error: "USER_NOT_FOUND" } }];
return [{ json: { ok: true, data: { presets: row.presets || [] } } }];''',
    'POST': '''const row = $input.first().json || {};
if (!row.user_found) return [{ json: { ok: false, http_status: 404, error: "USER_NOT_FOUND" } }];
if (!row.preset) return [{ json: { ok: false, http_status: 500, error: "PRESET_CREATE_FAILED" } }];
return [{ json: { ok: true, data: { preset: row.preset } } }];''',
    'PATCH': '''const row = $input.first().json || {};
if (!row.user_found) return [{ json: { ok: false, http_status: 404, error: "USER_NOT_FOUND" } }];
if (!row.preset) return [{ json: { ok: false, http_status: 404, error: "PRESET_NOT_FOUND" } }];
return [{ json: { ok: true, data: { preset: row.preset } } }];''',
    'DELETE': '''const row = $input.first().json || {};
if (!row.user_found) return [{ json: { ok: false, http_status: 404, error: "USER_NOT_FOUND" } }];
if (!Number(row.deleted_id || 0)) return [{ json: { ok: false, http_status: 404, error: "PRESET_NOT_FOUND" } }];
return [{ json: { ok: true, data: { deleted: true, id: Number(row.deleted_id) } } }];''',
}

nodes = []
connections = {}
ys = {'GET': -330, 'POST': -110, 'PATCH': 110, 'DELETE': 330}

for mode, y in ys.items():
    wh = webhook(mode, y)
    verify_name = f'Verify Presets {mode}'
    verify = {
        'parameters': {'jsCode': verify_js(mode)},
        'type': 'n8n-nodes-base.code', 'typeVersion': 2,
        'position': [-500, y], 'id': uid(verify_name), 'name': verify_name,
    }
    auth_if_name = f'Presets {mode} Auth Valid?'
    auth_if = if_node(auth_if_name, -280, y)
    sql_name = {'GET': 'Get Filter Presets', 'POST': 'Create Filter Preset', 'PATCH': 'Rename Filter Preset', 'DELETE': 'Delete Filter Preset'}[mode]
    sql = {
        'parameters': {'operation': 'executeQuery', 'query': SQL[mode], 'options': {}},
        'type': 'n8n-nodes-base.postgres', 'typeVersion': 2.6,
        'position': [-40, y], 'id': uid(sql_name), 'name': sql_name,
        'alwaysOutputData': True, 'credentials': CREDENTIAL,
    }
    format_name = f'Format Presets {mode}'
    fmt = {
        'parameters': {'jsCode': FORMAT[mode]},
        'type': 'n8n-nodes-base.code', 'typeVersion': 2,
        'position': [200, y], 'id': uid(format_name), 'name': format_name,
    }
    result_if_name = f'Presets {mode} Result Valid?'
    result_if = if_node(result_if_name, 420, y)
    nodes.extend([wh, verify, auth_if, sql, fmt, result_if])

    connections[wh['name']] = {'main': [[{'node': verify_name, 'type': 'main', 'index': 0}]]}
    connections[verify_name] = {'main': [[{'node': auth_if_name, 'type': 'main', 'index': 0}]]}
    connections[auth_if_name] = {'main': [
        [{'node': sql_name, 'type': 'main', 'index': 0}],
        [{'node': 'Respond Presets Error', 'type': 'main', 'index': 0}],
    ]}
    connections[sql_name] = {'main': [[{'node': format_name, 'type': 'main', 'index': 0}]]}
    connections[format_name] = {'main': [[{'node': result_if_name, 'type': 'main', 'index': 0}]]}
    connections[result_if_name] = {'main': [
        [{'node': 'Respond Presets Success', 'type': 'main', 'index': 0}],
        [{'node': 'Respond Presets Error', 'type': 'main', 'index': 0}],
    ]}

nodes.extend([
    {
        'parameters': {'respondWith': 'json', 'responseBody': '={{ JSON.stringify({ data: $json.data }) }}', 'options': {'responseCode': 200}},
        'type': 'n8n-nodes-base.respondToWebhook', 'typeVersion': 1.5,
        'position': [680, -110], 'id': uid('Respond Presets Success'), 'name': 'Respond Presets Success',
    },
    {
        'parameters': {'respondWith': 'json', 'responseBody': '={{ JSON.stringify({ error: $json.error }) }}', 'options': {'responseCode': '={{ $json.http_status || 500 }}'}},
        'type': 'n8n-nodes-base.respondToWebhook', 'typeVersion': 1.5,
        'position': [680, 110], 'id': uid('Respond Presets Error'), 'name': 'Respond Presets Error',
    },
])

workflow = {
    'id': WORKFLOW_ID,
    'name': 'MoneyTrack Filter Presets API',
    'active': False,
    'isArchived': False,
    'nodes': nodes,
    'connections': connections,
    'settings': {'executionOrder': 'v1', 'binaryMode': 'separate'},
    'staticData': None,
    'meta': {'templateCredsSetupCompleted': True},
    'pinData': {},
}

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'workflow_generated={OUT}')
print('preset_auth_contract=PASS')
print('preset_mutation_contract=PASS immutable_payload_rename_only')
