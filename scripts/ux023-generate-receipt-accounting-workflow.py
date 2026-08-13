#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / 'scripts/api-3-telegram-initdata-verifier.fragment.js').read_text(encoding='utf-8')
NS = uuid.UUID('4d8ca825-a525-4874-a144-a9f7fcb89e72')


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def node(node_type: str, name: str, parameters: dict, position: list[int], version: float | int = 2) -> dict:
    return {
        'parameters': parameters,
        'type': node_type,
        'typeVersion': version,
        'position': position,
        'id': uid(name),
        'name': name,
    }


def webhook(name: str, path: str, method: str, y: int) -> dict:
    result = node(
        'n8n-nodes-base.webhook', name,
        {'path': path, 'httpMethod': method, 'responseMode': 'responseNode', 'options': {}},
        [-700, y], 2.1,
    )
    result['webhookId'] = uid('webhook:' + name)
    return result


def postgres(name: str, query: str, y: int, credential_id: str, credential_name: str) -> dict:
    result = node('n8n-nodes-base.postgres', name, {'operation': 'executeQuery', 'query': query, 'options': {}}, [-10, y - 80], 2.6)
    result['credentials'] = {'postgres': {'id': credential_id, 'name': credential_name}}
    result['onError'] = 'continueRegularOutput'
    return result


AUTH_PREFIX = f'''const crypto=require("crypto");
{AUTH_FRAGMENT}
const headers=$json.headers||{{}},query=$json.query||{{}},body=$json.body||{{}};
const initData=headers["x-telegram-init-data"]||headers["X-Telegram-Init-Data"]||query.initData||query.init_data||null;
const auth=moneytrackVerifyTelegramInitData({{crypto,initData,botToken:$env.MONEYTRACK_BOT_TOKEN,maxAgeSeconds:$env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,maxFutureSkewSeconds:$env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS}});
if(!auth.ok)return [{{json:auth}}];
const fail=(code,http_status=400)=>[{{json:{{ok:false,http_status,error:{{code}}}}}}];
const id=(value,code)=>{{const raw=String(value??"").trim();if(!/^\\d+$/.test(raw))return {{error:code}};return {{value:Number(raw)}};}};
'''

GET_VERIFY = AUTH_PREFIX + '''const tx=id(query.transaction_id,"TRANSACTION_ID_INVALID");if(tx.error)return fail(tx.error);return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,transaction_id:tx.value}}];'''
ACCOUNTING_VERIFY = AUTH_PREFIX + '''const receipt=id(body.receipt_id,"RECEIPT_ID_INVALID");if(receipt.error)return fail(receipt.error);const account=id(body.account_id,"ACCOUNT_ID_INVALID");if(account.error)return fail(account.error);const currency=String(body.currency||"").trim().toUpperCase();if(!/^[A-Z0-9]{3,12}$/.test(currency))return fail("CURRENCY_REQUIRED");return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,receipt_id:receipt.value,account_id:account.value,currency}}];'''
CATEGORY_VERIFY = AUTH_PREFIX + '''const item=id(body.receipt_item_id,"RECEIPT_ITEM_ID_INVALID");if(item.error)return fail(item.error);let category="NULL";if(body.category_id!==null&&body.category_id!==undefined&&body.category_id!==""){const parsed=id(body.category_id,"CATEGORY_ID_INVALID");if(parsed.error)return fail(parsed.error);category=String(parsed.value);}return [{json:{ok:true,telegram_user_id:auth.telegram_user_id,receipt_item_id:item.value,category_sql:category}}];'''

INTERNAL_USER = """(select u.id from moneytrack.app_users u where u.telegram_user_id={{ $json.telegram_user_id }}::bigint limit 1)"""
GET_QUERY = """select * from moneytrack.api_receipt_detail_read_model_v1({{ $json.telegram_user_id }}::bigint,{{ $json.transaction_id }}::bigint);"""
ACCOUNTING_QUERY = f"""select * from moneytrack.receipt_update_accounting_v1({INTERNAL_USER},{{{{ $json.receipt_id }}}}::bigint,{{{{ $json.account_id }}}}::bigint,'{{{{ $json.currency }}}}'::text);"""
CATEGORY_QUERY = f"""select * from moneytrack.receipt_set_item_category_v2({INTERNAL_USER},{{{{ $json.receipt_item_id }}}}::bigint,{{{{ $json.category_sql }}}});"""
GET_FORMAT = '''const row=$input.first().json||{};if(row.error)return [{json:{ok:false,http_status:400,error:{code:"DOMAIN_ERROR"}}}];return [{json:{ok:true,http_status:200,data:{receipt:row.receipt||null}}}];'''
MUTATION_FORMAT = '''const row=$input.first().json||{};if(row.error){const message=String(row.error.message||row.error||"DOMAIN_ERROR");const match=message.match(/\\b([A-Z][A-Z0-9_]+)\\b/);return [{json:{ok:false,http_status:400,error:{code:match?match[1]:"DOMAIN_ERROR"}}}];}return [{json:{ok:true,http_status:200,data:row}}];'''


def build(credential_id: str, credential_name: str) -> dict:
    routes = [
        ('Receipt GET', 'api/v1/receipt', 'GET', GET_VERIFY, GET_QUERY, GET_FORMAT, 0),
        ('Receipt Accounting PATCH', 'api/v1/receipt/accounting', 'PATCH', ACCOUNTING_VERIFY, ACCOUNTING_QUERY, MUTATION_FORMAT, 300),
        ('Receipt Item Category PATCH', 'api/v1/receipt-item/category', 'PATCH', CATEGORY_VERIFY, CATEGORY_QUERY, MUTATION_FORMAT, 600),
    ]
    nodes = []
    connections = {}
    for prefix, path, method, verifier, query, formatter, y in routes:
        wh, vr, ok, db, fm, rp = [prefix + suffix for suffix in (' Webhook', ' Verify', ' Auth OK', ' Backend', ' Format', ' Respond')]
        nodes.extend([
            webhook(wh, path, method, y),
            node('n8n-nodes-base.code', vr, {'jsCode': verifier}, [-470, y]),
            node('n8n-nodes-base.if', ok, {'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict', 'version': 2}, 'conditions': [{'id': uid(ok + ':condition'), 'leftValue': '={{ $json.ok }}', 'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}], 'combinator': 'and'}, 'options': {}}, [-250, y], 2.2),
            postgres(db, query, y, credential_id, credential_name),
            node('n8n-nodes-base.code', fm, {'jsCode': formatter}, [210, y - 80]),
            node('n8n-nodes-base.respondToWebhook', rp, {'respondWith': 'json', 'responseBody': '={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}', 'options': {'responseCode': '={{ $json.http_status || 200 }}'}}, [440, y], 1.4),
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
