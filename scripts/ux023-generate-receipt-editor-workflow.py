#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / 'scripts/api-3-telegram-initdata-verifier.fragment.js').read_text(encoding='utf-8')
NS = uuid.UUID('ce849b46-1f23-4bf4-b3b7-83ed6ddeebc5')


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def webhook(name: str, path: str, method: str, y: int) -> dict:
    return {
        'parameters': {'path': path, 'httpMethod': method, 'responseMode': 'responseNode', 'options': {}},
        'type': 'n8n-nodes-base.webhook', 'typeVersion': 2.1, 'position': [-700, y],
        'id': uid(name), 'name': name, 'webhookId': uid('webhook:' + name),
    }


def code(name: str, js: str, x: int, y: int) -> dict:
    return {'parameters': {'jsCode': js}, 'type': 'n8n-nodes-base.code', 'typeVersion': 2, 'position': [x, y], 'id': uid(name), 'name': name}


def if_node(name: str, y: int) -> dict:
    return {
        'parameters': {'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict', 'version': 2}, 'conditions': [{'id': uid(name + ':condition'), 'leftValue': '={{ $json.ok }}', 'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}], 'combinator': 'and'}, 'options': {}},
        'type': 'n8n-nodes-base.if', 'typeVersion': 2.2, 'position': [-250, y], 'id': uid(name), 'name': name,
    }


def postgres(name: str, query: str, y: int, credential_id: str, credential_name: str) -> dict:
    return {
        'parameters': {'operation': 'executeQuery', 'query': query, 'options': {}},
        'type': 'n8n-nodes-base.postgres', 'typeVersion': 2.6, 'position': [-10, y - 80],
        'id': uid(name), 'name': name,
        'credentials': {'postgres': {'id': credential_id, 'name': credential_name}},
        'onError': 'continueRegularOutput',
    }


def respond(name: str, y: int) -> dict:
    return {
        'parameters': {'respondWith': 'json', 'responseBody': '={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}', 'options': {'responseCode': '={{ $json.http_status || 200 }}'}},
        'type': 'n8n-nodes-base.respondToWebhook', 'typeVersion': 1.4, 'position': [440, y], 'id': uid(name), 'name': name,
    }


AUTH_PREFIX = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const headers=$json.headers||{{}}; const query=$json.query||{{}}; const body=$json.body||{{}};
const initData=headers["x-telegram-init-data"]||headers["X-Telegram-Init-Data"]||query.initData||query.init_data||null;
const auth=moneytrackVerifyTelegramInitData({{crypto,initData,botToken:$env.MONEYTRACK_BOT_TOKEN,maxAgeSeconds:$env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,maxFutureSkewSeconds:$env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS}});
if(!auth.ok)return [{{json:auth}}];
const fail=(code,httpStatus=400)=>[{{json:{{ok:false,http_status:httpStatus,error:{{code}}}}}}];
const id=(value,code)=>{{const raw=String(value??"").trim(); if(!/^\\d+$/.test(raw))return {{error:code}}; return {{value:Number(raw)}};}};
'''

GET_VERIFY = AUTH_PREFIX + '''const tx=id(query.transaction_id,"TRANSACTION_ID_INVALID"); if(tx.error)return fail(tx.error); return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,transaction_id:tx.value}}];'''
CURRENCY_VERIFY = AUTH_PREFIX + '''const receipt=id(body.receipt_id,"RECEIPT_ID_INVALID"); if(receipt.error)return fail(receipt.error); const currency=String(body.currency||"").trim().toUpperCase(); if(!/^[A-Z0-9]{3,12}$/.test(currency))return fail("CURRENCY_REQUIRED"); return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,receipt_id:receipt.value,currency}}];'''
CATEGORY_VERIFY = AUTH_PREFIX + '''const item=id(body.receipt_item_id,"RECEIPT_ITEM_ID_INVALID"); if(item.error)return fail(item.error); let category="NULL"; if(body.category_id!==null&&body.category_id!==undefined&&body.category_id!==""){const parsed=id(body.category_id,"CATEGORY_ID_INVALID"); if(parsed.error)return fail(parsed.error); category=String(parsed.value);} return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,receipt_item_id:item.value,category_sql:category}}];'''

GET_QUERY = """select * from moneytrack.api_receipt_detail_read_model_v1(
  {{ $json.telegram_user_id }}::bigint,
  {{ $json.transaction_id }}::bigint
);"""

INTERNAL_USER_SQL = """(
  select u.id from moneytrack.app_users u
  where u.telegram_user_id = {{ $json.telegram_user_id }}::bigint
  limit 1
)"""

CURRENCY_QUERY = f"""select * from moneytrack.receipt_set_currency_v1(
  {INTERNAL_USER_SQL},
  {{{{ $json.receipt_id }}}}::bigint,
  '{{{{ $json.currency }}}}'::text
);"""

CATEGORY_QUERY = f"""select * from moneytrack.receipt_set_item_category_v2(
  {INTERNAL_USER_SQL},
  {{{{ $json.receipt_item_id }}}}::bigint,
  {{{{ $json.category_sql }}}}
);"""

GET_FORMAT = '''const row=$input.first().json||{}; if(row.error){return [{json:{ok:false,http_status:400,error:{code:"DOMAIN_ERROR"}}}];} return [{json:{ok:true,http_status:200,data:{receipt:row.receipt||null}}}];'''
MUTATION_FORMAT = '''const row=$input.first().json||{}; if(row.error){const message=String(row.error.message||row.error||"DOMAIN_ERROR"); const match=message.match(/\\b([A-Z][A-Z0-9_]+)\\b/); return [{json:{ok:false,http_status:400,error:{code:match?match[1]:"DOMAIN_ERROR"}}}];} return [{json:{ok:true,http_status:200,data:row}}];'''


def build(credential_id: str, credential_name: str) -> dict:
    nodes = []
    connections = {}
    routes = [
        ('Receipt GET', 'api/v1/receipt', 'GET', GET_VERIFY, GET_QUERY, GET_FORMAT, 0),
        ('Receipt Currency PATCH', 'api/v1/receipt/currency', 'PATCH', CURRENCY_VERIFY, CURRENCY_QUERY, MUTATION_FORMAT, 300),
        ('Receipt Item Category PATCH', 'api/v1/receipt-item/category', 'PATCH', CATEGORY_VERIFY, CATEGORY_QUERY, MUTATION_FORMAT, 600),
    ]
    for prefix, path, method, verifier, query, formatter, y in routes:
        wh = prefix + ' Webhook'; vr = prefix + ' Verify'; ok = prefix + ' Auth OK'; db = prefix + ' Backend'; fm = prefix + ' Format'; rp = prefix + ' Respond'
        nodes.extend([
            webhook(wh, path, method, y), code(vr, verifier, -470, y), if_node(ok, y),
            postgres(db, query, y, credential_id, credential_name), code(fm, formatter, 210, y - 80), respond(rp, y),
        ])
        connections[wh] = {'main': [[{'node': vr, 'type': 'main', 'index': 0}]]}
        connections[vr] = {'main': [[{'node': ok, 'type': 'main', 'index': 0}]]}
        connections[ok] = {'main': [[{'node': db, 'type': 'main', 'index': 0}], [{'node': rp, 'type': 'main', 'index': 0}]]}
        connections[db] = {'main': [[{'node': fm, 'type': 'main', 'index': 0}]]}
        connections[fm] = {'main': [[{'node': rp, 'type': 'main', 'index': 0}]]}
    return {'id': 'UX023ReceiptEditor202608', 'name': 'MoneyTrack Receipt Editor API', 'nodes': nodes, 'connections': connections, 'settings': {'executionOrder': 'v1'}, 'active': False}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--postgres-credential-id', default='tM27zg5m7tREo2ep')
    parser.add_argument('--postgres-credential-name', default='Postgres account')
    args = parser.parse_args()
    workflow = build(args.postgres_credential_id, args.postgres_credential_name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(workflow, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f"receipt_editor={workflow['id']} nodes={len(workflow['nodes'])} path={args.output}")


if __name__ == '__main__':
    main()
