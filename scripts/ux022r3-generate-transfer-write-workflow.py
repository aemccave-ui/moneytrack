#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / 'scripts/api-3-telegram-initdata-verifier.fragment.js').read_text(encoding='utf-8')
NS = uuid.UUID('9db5d32f-4a76-47cf-a488-251366b20db2')


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def webhook(name: str, method: str, y: int) -> dict:
    return {
        'parameters': {'path': 'api/v1/transfer', 'httpMethod': method, 'responseMode': 'responseNode', 'options': {}},
        'type': 'n8n-nodes-base.webhook', 'typeVersion': 2.1, 'position': [-680, y],
        'id': uid(name), 'name': name, 'webhookId': uid('webhook:' + name),
    }


def code(name: str, js: str, x: int, y: int) -> dict:
    return {'parameters': {'jsCode': js}, 'type': 'n8n-nodes-base.code', 'typeVersion': 2, 'position': [x, y], 'id': uid(name), 'name': name}


def if_node(name: str, y: int) -> dict:
    return {
        'parameters': {'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict', 'version': 2}, 'conditions': [{'id': uid(name + ':condition'), 'leftValue': '={{ $json.ok }}', 'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}], 'combinator': 'and'}, 'options': {}},
        'type': 'n8n-nodes-base.if', 'typeVersion': 2.2, 'position': [-240, y], 'id': uid(name), 'name': name,
    }


def postgres(name: str, query: str, y: int, credential_id: str, credential_name: str) -> dict:
    return {
        'parameters': {'operation': 'executeQuery', 'query': query, 'options': {}},
        'type': 'n8n-nodes-base.postgres', 'typeVersion': 2.6, 'position': [-20, y - 70],
        'id': uid(name), 'name': name,
        'credentials': {'postgres': {'id': credential_id, 'name': credential_name}},
        'onError': 'continueRegularOutput',
    }


def respond(name: str, y: int) -> dict:
    return {
        'parameters': {'respondWith': 'json', 'responseBody': '={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}', 'options': {'responseCode': '={{ $json.http_status || 200 }}'}},
        'type': 'n8n-nodes-base.respondToWebhook', 'typeVersion': 1.4, 'position': [430, y], 'id': uid(name), 'name': name,
    }


VERIFY_COMMON = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const headers = $json.headers || {{}};
const query = $json.query || {{}};
const body = $json.body || {{}};
const initData = headers["x-telegram-init-data"] || headers["X-Telegram-Init-Data"] || query.initData || query.init_data || null;
const auth = moneytrackVerifyTelegramInitData({{ crypto, initData, botToken:$env.MONEYTRACK_BOT_TOKEN, maxAgeSeconds:$env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS, maxFutureSkewSeconds:$env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS }});
if (!auth.ok) return [{{json:auth}}];
const fail=(code,httpStatus=400)=>[{{json:{{ok:false,http_status:httpStatus,error:{{code}}}}}}];
const id=(value,code)=>{{const raw=String(value??"").trim(); if(!/^\\d+$/.test(raw)) return {{error:code}}; return {{value:Number(raw)}};}};
const text=(value)=>String(value??"").replaceAll("'","''");
'''

GET_VERIFY = VERIFY_COMMON + '''const transfer=id(query.id??query.transfer_id,"TRANSFER_ID_INVALID"); if(transfer.error)return fail(transfer.error); return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,transfer_id:transfer.value}}];'''
DELETE_VERIFY = GET_VERIFY
WRITE_VERIFY = VERIFY_COMMON + '''const from=id(body.from_account_id,"FROM_ACCOUNT_ID_INVALID"); if(from.error)return fail(from.error); const to=id(body.to_account_id,"TO_ACCOUNT_ID_INVALID"); if(to.error)return fail(to.error); const amount=Number(body.from_amount); if(!Number.isFinite(amount)||amount<=0)return fail("INVALID_TRANSFER_AMOUNT"); const date=new Date(body.transfer_date); if(Number.isNaN(date.getTime()))return fail("DATE_INVALID"); const transferType=String(body.transfer_type||"transfer").trim(); if(!["transfer","exchange","transferexchange"].includes(transferType))return fail("INVALID_TRANSFER_TYPE"); const out={ok:true,telegram_user_id:auth.telegram_user_id,from_account_id:from.value,to_account_id:to.value,from_amount_sql:String(amount),date_sql:text(date.toISOString()),type_sql:text(transferType)};'''
POST_VERIFY = WRITE_VERIFY + '''const request=id(body.request_id,"REQUEST_ID_INVALID"); if(request.error)return fail(request.error); out.request_id=request.value; return [{json:out}];'''
PATCH_VERIFY = WRITE_VERIFY + '''const transfer=id(body.transfer_id,"TRANSFER_ID_INVALID"); if(transfer.error)return fail(transfer.error); out.transfer_id=transfer.value; return [{json:out}];'''

INTERNAL_USER_ID_SQL = """(
  select u.id
  from moneytrack.app_users u
  where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
  limit 1
)"""

GET_QUERY = f"""select * from moneytrack.finance_get_transfer_v1(
  {INTERNAL_USER_ID_SQL},
  {{{{ $json.transfer_id }}}}::bigint
);"""

POST_QUERY = f"""select * from moneytrack.finance_create_transfer_v1(
  {INTERNAL_USER_ID_SQL},
  {{{{ $json.from_account_id }}}}::bigint,
  {{{{ $json.to_account_id }}}}::bigint,
  {{{{ $json.from_amount_sql }}}}::numeric,
  null::numeric,
  '{{{{ $json.date_sql }}}}'::timestamptz,
  '{{{{ $json.type_sql }}}}'::text,
  'miniapp'::text,
  {{{{ $json.request_id }}}}::bigint
);"""

PATCH_QUERY = f"""select * from moneytrack.finance_update_transfer_v1(
  {INTERNAL_USER_ID_SQL},
  {{{{ $json.transfer_id }}}}::bigint,
  {{{{ $json.from_account_id }}}}::bigint,
  {{{{ $json.to_account_id }}}}::bigint,
  {{{{ $json.from_amount_sql }}}}::numeric,
  '{{{{ $json.date_sql }}}}'::timestamptz,
  '{{{{ $json.type_sql }}}}'::text
);"""

DELETE_QUERY = f"""select * from moneytrack.finance_delete_transfer_v1(
  {INTERNAL_USER_ID_SQL},
  {{{{ $json.transfer_id }}}}::bigint
);"""

FORMAT = '''const row=$input.first().json||{}; if(row.error){const raw=String(row.error.message||row.error||"DOMAIN_ERROR"); const match=raw.match(/\\b([A-Z][A-Z0-9_]+)\\b/); return [{json:{ok:false,http_status:400,error:{code:match?match[1]:"DOMAIN_ERROR"}}}];} return [{json:{ok:true,http_status:200,data:{transfer:row}}}];'''


def build(credential_id: str, credential_name: str) -> dict:
    nodes = []
    connections = {}
    routes = [
        ('Transfer GET', 'GET', GET_VERIFY, GET_QUERY, 0),
        ('Transfer POST', 'POST', POST_VERIFY, POST_QUERY, 250),
        ('Transfer PATCH', 'PATCH', PATCH_VERIFY, PATCH_QUERY, 500),
        ('Transfer DELETE', 'DELETE', DELETE_VERIFY, DELETE_QUERY, 750),
    ]
    for prefix, method, verifier, query, y in routes:
        wh = prefix + ' Webhook'; vr = prefix + ' Verify'; ok = prefix + ' Auth OK'; db = prefix + ' Backend'; fm = prefix + ' Format'; rp = prefix + ' Respond'
        nodes.extend([
            webhook(wh, method, y), code(vr, verifier, -460, y), if_node(ok, y),
            postgres(db, query, y, credential_id, credential_name), code(fm, FORMAT, 200, y - 70), respond(rp, y),
        ])
        connections[wh] = {'main': [[{'node': vr, 'type': 'main', 'index': 0}]]}
        connections[vr] = {'main': [[{'node': ok, 'type': 'main', 'index': 0}]]}
        connections[ok] = {'main': [[{'node': db, 'type': 'main', 'index': 0}], [{'node': rp, 'type': 'main', 'index': 0}]]}
        connections[db] = {'main': [[{'node': fm, 'type': 'main', 'index': 0}]]}
        connections[fm] = {'main': [[{'node': rp, 'type': 'main', 'index': 0}]]}
    return {'id':'UX022TransferWrite202608','name':'MoneyTrack Transfer Editor API','nodes':nodes,'connections':connections,'settings':{'executionOrder':'v1'},'active':False}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--postgres-credential-id', default='tM27zg5m7tREo2ep')
    parser.add_argument('--postgres-credential-name', default='Postgres account')
    args = parser.parse_args()
    workflow = build(args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"transfer_write={workflow['id']} nodes={len(workflow['nodes'])} path={args.output}")


if __name__ == '__main__':
    main()
