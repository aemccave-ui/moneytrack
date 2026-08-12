#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / 'scripts/api-3-telegram-initdata-verifier.fragment.js').read_text(encoding='utf-8')
NS = uuid.UUID('45cd32a1-9a16-48f4-aefd-d77dc18a1c2d')


def uid(value: str) -> str:
    return str(uuid.uuid5(NS, value))


def build(credential_id: str, credential_name: str) -> dict:
    verify = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const headers=$json.headers||{{}}; const query=$json.query||{{}}; const body=$json.body||{{}};
const initData=headers["x-telegram-init-data"]||headers["X-Telegram-Init-Data"]||query.initData||query.init_data||null;
const auth=moneytrackVerifyTelegramInitData({{crypto,initData,botToken:$env.MONEYTRACK_BOT_TOKEN,maxAgeSeconds:$env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,maxFutureSkewSeconds:$env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS}});
if(!auth.ok)return [{{json:auth}}];
const raw=String(body.category_id??"").trim(); if(!/^\\d+$/.test(raw))return [{{json:{{ok:false,http_status:400,error:{{code:"CATEGORY_ID_INVALID"}}}}}}];
const name=String(body.name||"").trim(); if(!name)return [{{json:{{ok:false,http_status:400,error:{{code:"CATEGORY_NAME_REQUIRED"}}}}}}];
const flow=String(body.flow_type||"").trim().toLowerCase(); if(!["income","expense"].includes(flow))return [{{json:{{ok:false,http_status:400,error:{{code:"CATEGORY_FLOW_TYPE_INVALID"}}}}}}];
const esc=(value)=>String(value).replaceAll("'","''");
return [{{json:{{ok:true,telegram_user_id:auth.telegram_user_id,category_id:Number(raw),name_sql:esc(name),flow_sql:esc(flow)}}}}];'''
    query = """select * from moneytrack.category_update_v1(
  {{ $json.telegram_user_id }}::bigint,
  {{ $json.category_id }}::bigint,
  '{{ $json.name_sql }}'::text,
  '{{ $json.flow_sql }}'::text
);"""
    fmt = '''const row=$input.first().json||{};
if(row.error){const message=String(row.error.message||row.error||"DOMAIN_ERROR"); const match=message.match(/\\b([A-Z][A-Z0-9_]+)\\b/); return [{json:{ok:false,http_status:400,error:{code:match?match[1]:"DOMAIN_ERROR"}}}];}
return [{json:{ok:true,http_status:200,data:{category:row.category||row}}}];'''
    names = ['Category PATCH Webhook','Category PATCH Verify','Category PATCH Auth OK','Category PATCH Backend','Category PATCH Format','Category PATCH Respond']
    nodes = [
        {'parameters':{'path':'api/v1/categories','httpMethod':'PATCH','responseMode':'responseNode','options':{}},'type':'n8n-nodes-base.webhook','typeVersion':2.1,'position':[-680,0],'id':uid(names[0]),'name':names[0],'webhookId':uid('webhook:'+names[0])},
        {'parameters':{'jsCode':verify},'type':'n8n-nodes-base.code','typeVersion':2,'position':[-460,0],'id':uid(names[1]),'name':names[1]},
        {'parameters':{'conditions':{'options':{'caseSensitive':True,'leftValue':'','typeValidation':'strict','version':2},'conditions':[{'id':uid('condition'),'leftValue':'={{ $json.ok }}','rightValue':'','operator':{'type':'boolean','operation':'true','singleValue':True}}],'combinator':'and'},'options':{}},'type':'n8n-nodes-base.if','typeVersion':2.2,'position':[-240,0],'id':uid(names[2]),'name':names[2]},
        {'parameters':{'operation':'executeQuery','query':query,'options':{}},'type':'n8n-nodes-base.postgres','typeVersion':2.6,'position':[-20,-80],'id':uid(names[3]),'name':names[3],'credentials':{'postgres':{'id':credential_id,'name':credential_name}},'onError':'continueRegularOutput'},
        {'parameters':{'jsCode':fmt},'type':'n8n-nodes-base.code','typeVersion':2,'position':[200,-80],'id':uid(names[4]),'name':names[4]},
        {'parameters':{'respondWith':'json','responseBody':'={{ JSON.stringify($json.ok === false ? { ok:false, error:$json.error } : { ok:true, data:$json.data }) }}','options':{'responseCode':'={{ $json.http_status || 200 }}'}},'type':'n8n-nodes-base.respondToWebhook','typeVersion':1.4,'position':[430,0],'id':uid(names[5]),'name':names[5]},
    ]
    connections = {
        names[0]:{'main':[[{'node':names[1],'type':'main','index':0}]]},
        names[1]:{'main':[[{'node':names[2],'type':'main','index':0}]]},
        names[2]:{'main':[[{'node':names[3],'type':'main','index':0}],[{'node':names[5],'type':'main','index':0}]]},
        names[3]:{'main':[[{'node':names[4],'type':'main','index':0}]]},
        names[4]:{'main':[[{'node':names[5],'type':'main','index':0}]]},
    }
    return {'id':'UX022CategorySettings202608','name':'MoneyTrack Category Settings API','nodes':nodes,'connections':connections,'settings':{'executionOrder':'v1'},'active':False}


def main() -> None:
    parser=argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--postgres-credential-id', default='tM27zg5m7tREo2ep')
    parser.add_argument('--postgres-credential-name', default='Postgres account')
    args=parser.parse_args()
    workflow=build(args.postgres_credential_id,args.postgres_credential_name)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(workflow,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f"category_settings={workflow['id']} nodes={len(workflow['nodes'])} path={args.output}")


if __name__ == '__main__':
    main()
