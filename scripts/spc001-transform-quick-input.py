#!/usr/bin/env python3
"""SPC-001: fail-closed transform of the canonical UX-022R3 Quick Input API.

Input must be the deterministic UX022QuickInput202608 candidate. The transport
contract stays Telegram InitData -> SEC-001 Class B -> backend, but the financial
context becomes actor + untrusted requested Space and every ingress carries a
stable capture_source_ref supplied by the MiniApp request.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUTH_FRAGMENT = (ROOT / "scripts/api-3-telegram-initdata-verifier.fragment.js").read_text(encoding="utf-8").strip()
WORKFLOW_ID = "UX022QuickInput202608"

TARGETS = {
    "Photo Verify", "Photo User Context", "Photo Prepare",
    "Text Verify", "Text User Context", "Text Prepare",
    "Voice Verify", "Voice User Context", "Voice Prepare", "Voice To Text",
}

VERIFY = f'''const crypto = require("crypto");
{AUTH_FRAGMENT}
const item = $input.first();
const envelope = item.json || {{}};
const headers = envelope.headers || {{}};
const query = envelope.query || {{}};
const body = envelope.body ?? null;
const initData = headers["x-telegram-init-data"] || headers["X-Telegram-Init-Data"] || query.initData || query.init_data || null;
const auth = moneytrackVerifyTelegramInitData({{
  crypto,
  initData,
  botToken:$env.MONEYTRACK_BOT_TOKEN,
  maxAgeSeconds:$env.MONEYTRACK_INIT_DATA_MAX_AGE_SECONDS,
  maxFutureSkewSeconds:$env.MONEYTRACK_INIT_DATA_MAX_FUTURE_SKEW_SECONDS
}});
if (!auth.ok) return [{{json:auth}}];
const rawSpace=String(headers["x-moneytrack-space-id"] || headers["X-MoneyTrack-Space-Id"] || "").trim();
if(!/^[1-9]\\d*$/.test(rawSpace)) return [{{json:{{ok:false,http_status:400,error:{{code:"SPACE_REQUIRED"}}}}}}];
const spaceId=Number(rawSpace);
if(!Number.isSafeInteger(spaceId)) return [{{json:{{ok:false,http_status:400,error:{{code:"SPACE_INVALID"}}}}}}];
let requestId="";
if(body && typeof body === "object" && !Array.isArray(body)) requestId=String(body.request_id ?? "").trim();
if(!requestId) requestId=String(query.request_id ?? "").trim();
if(!/^[A-Za-z0-9:_-]{{8,160}}$/.test(requestId)) return [{{json:{{ok:false,http_status:400,error:{{code:"CAPTURE_SOURCE_REF_REQUIRED"}}}}}}];
return [{{json:{{
  ok:true,
  telegram_user_id:auth.telegram_user_id,
  auth_contract_version:auth.auth_contract_version,
  space_id:spaceId,
  capture_source_ref:`miniapp:${{requestId}}`,
  body
}},binary:item.binary||{{}}}}];'''

USER_CONTEXT_QUERY = r'''select
    ctx.actor_user_id::bigint as user_id,
    ctx.space_id::bigint as space_id,
    {{ "'" + String($json.capture_source_ref || "").replaceAll("'", "''") + "'" }}::text as capture_source_ref,
    u.telegram_user_id::bigint as telegram_user_id,
    coalesce(us.language_code,u.language_code,'en')::text as language_code,
    coalesce(u.language_code,us.language_code,'en')::text as fallback_language_code,
    upper(s.base_currency)::text as base_currency,
    upper(s.report_currency)::text as report_currency,
    s.default_expense_account_id::bigint as default_expense_account_id,
    s.default_income_account_id::bigint as default_income_account_id
from moneytrack.spc001_resolve_actor_space_v1(
    {{ $json.telegram_user_id }}::bigint,
    {{ $json.space_id }}::bigint
) ctx
join moneytrack.app_users u on u.id=ctx.actor_user_id
join moneytrack.user_settings us on us.user_id=u.id
join moneytrack.space_financial_settings s on s.space_id=ctx.space_id
limit 1;'''

PHOTO_PREPARE = r'''const auth=$('Photo Verify').first();
const user=$input.first().json||{};
const binary=auth.binary||{};
const fail=(code,http_status=400)=>[{json:{ok:false,http_status,error:{code}}}];
if(!user.user_id||!user.space_id) return fail('SPACE_CONTEXT_NOT_FOUND',404);
if(!user.capture_source_ref) return fail('CAPTURE_SOURCE_REF_REQUIRED');
if(!Object.keys(binary).length) return fail('PHOTO_BINARY_MISSING');
return [{json:{
  ok:true,user_id:Number(user.user_id),space_id:Number(user.space_id),
  capture_source_ref:String(user.capture_source_ref),telegram_user_id:Number(user.telegram_user_id),
  telegram_chat_id:null,message_caption:null,message_date:Math.floor(Date.now()/1000),
  message_type:'photo',source_type:'photo_receipt',language_code:user.language_code||'en',
  fallback_language_code:user.fallback_language_code||user.language_code||'en',
  base_currency:user.base_currency||'EUR',report_currency:user.report_currency||user.base_currency||'EUR',
  default_expense_account_id:user.default_expense_account_id??null,
  default_income_account_id:user.default_income_account_id??null,test_mode:false
},binary}];'''

TEXT_PREPARE = r'''const auth=$('Text Verify').first();
const user=$input.first().json||{};
const fail=(code,http_status=400)=>[{json:{ok:false,http_status,error:{code}}}];
if(!user.user_id||!user.space_id) return fail('SPACE_CONTEXT_NOT_FOUND',404);
if(!user.capture_source_ref) return fail('CAPTURE_SOURCE_REF_REQUIRED');
let body=auth.json?.body;
if(typeof body==='string'){const raw=body.trim();if(raw.startsWith('{')){try{body=JSON.parse(raw)}catch{body=raw}}}
const messageText=String((body&&typeof body==='object'?(body.text??body.message_text??''):body)??'').trim();
if(!messageText) return fail('TEXT_REQUIRED');
return [{json:{
  ok:true,user_id:Number(user.user_id),space_id:Number(user.space_id),capture_source_ref:String(user.capture_source_ref),
  telegram_user_id:Number(user.telegram_user_id),telegram_chat_id:null,telegram_username:null,telegram_first_name:null,
  telegram_language_code:user.language_code||'en',language_code:user.language_code||'en',
  fallback_language_code:user.fallback_language_code||user.language_code||'en',base_currency:user.base_currency||'EUR',
  report_currency:user.report_currency||user.base_currency||'EUR',default_expense_account_id:user.default_expense_account_id??null,
  default_income_account_id:user.default_income_account_id??null,message_text:messageText,message_caption:null,
  message_date:Math.floor(Date.now()/1000),message_type:'text',source_type:'text',test_mode:false
}}];'''

VOICE_PREPARE = r'''const auth=$('Voice Verify').first();
const user=$input.first().json||{};
const binary=auth.binary||{};
const fail=(code,http_status=400)=>[{json:{ok:false,http_status,error:{code}}}];
if(!user.user_id||!user.space_id) return fail('SPACE_CONTEXT_NOT_FOUND',404);
if(!user.capture_source_ref) return fail('CAPTURE_SOURCE_REF_REQUIRED');
if(!Object.keys(binary).length) return fail('VOICE_BINARY_MISSING');
return [{json:{
  ok:true,user_id:Number(user.user_id),space_id:Number(user.space_id),capture_source_ref:String(user.capture_source_ref),
  telegram_user_id:Number(user.telegram_user_id),telegram_chat_id:null,message_date:Math.floor(Date.now()/1000),
  message_type:'voice',source_type:'voice',language_code:user.language_code||'en',
  fallback_language_code:user.fallback_language_code||user.language_code||'en',base_currency:user.base_currency||'EUR',
  report_currency:user.report_currency||user.base_currency||'EUR',default_expense_account_id:user.default_expense_account_id??null,
  default_income_account_id:user.default_income_account_id??null,test_mode:false
},binary}];'''

VOICE_TO_TEXT = r'''const voice=$input.first().json||{};
const user=$('Voice User Context').first().json||{};
const fail=(code,http_status=400)=>[{json:{ok:false,http_status,error:{code}}}];
if(voice.error) return fail('VOICE_PROCESSOR_ERROR',500);
const messageText=String(voice.voice_text??voice.message_text??voice.transcript??voice.text??voice.output_text??voice.output??'').trim();
if(!messageText) return fail('VOICE_TEXT_EMPTY');
return [{json:{
  ok:true,user_id:Number(user.user_id),space_id:Number(user.space_id),capture_source_ref:String(user.capture_source_ref||''),
  telegram_user_id:Number(user.telegram_user_id),telegram_chat_id:null,message_text:messageText,voice_text:messageText,
  message_type:'voice',source_type:'voice',language_code:user.language_code||'en',
  fallback_language_code:user.fallback_language_code||user.language_code||'en',base_currency:user.base_currency||'EUR',
  report_currency:user.report_currency||user.base_currency||'EUR',default_expense_account_id:user.default_expense_account_id??null,
  default_income_account_id:user.default_income_account_id??null,test_mode:false
}}];'''

REPLACEMENTS = {
    "Photo Verify": ("jsCode", VERIFY),
    "Photo User Context": ("query", USER_CONTEXT_QUERY),
    "Photo Prepare": ("jsCode", PHOTO_PREPARE),
    "Text Verify": ("jsCode", VERIFY),
    "Text User Context": ("query", USER_CONTEXT_QUERY),
    "Text Prepare": ("jsCode", TEXT_PREPARE),
    "Voice Verify": ("jsCode", VERIFY),
    "Voice User Context": ("query", USER_CONTEXT_QUERY),
    "Voice Prepare": ("jsCode", VOICE_PREPARE),
    "Voice To Text": ("jsCode", VOICE_TO_TEXT),
}


def unwrap(doc):
    if isinstance(doc,list):
        if len(doc)!=1: raise SystemExit(f"expected one workflow, got {len(doc)}")
        return doc[0],True
    if isinstance(doc,dict): return doc,False
    raise SystemExit("input must be workflow object or one-element array")


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    args=ap.parse_args()
    src=json.loads(Path(args.input).read_text(encoding="utf-8"))
    workflow,was_array=unwrap(src)
    if workflow.get("id")!=WORKFLOW_ID:
        raise SystemExit(f"unexpected workflow id: {workflow.get('id')!r}")
    names={n.get('name') for n in workflow.get('nodes',[])}
    missing=TARGETS-names
    if missing: raise SystemExit(f"missing target nodes: {sorted(missing)}")
    out=copy.deepcopy(workflow)
    changed=[]
    for n in out['nodes']:
        name=n.get('name')
        if name not in REPLACEMENTS: continue
        field,value=REPLACEMENTS[name]
        params=n.setdefault('parameters',{})
        if field=='query' and params.get('operation')!='executeQuery':
            raise SystemExit(f"{name!r} is not executeQuery")
        params[field]=value
        changed.append(name)
    if set(changed)!=TARGETS: raise SystemExit(f"changed mismatch: {sorted(changed)}")
    output=[out] if was_array else out
    Path(args.output).write_text(json.dumps(output,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('SPC-001 Quick Input candidate created')
    print(f'workflow_id={WORKFLOW_ID}')
    print('changed_nodes='+', '.join(sorted(changed)))
    print('destination_space=untrusted_header_then_server_membership')
    print('capture_source_ref=required_client_request_id')
    print('runtime_mutation=NONE')


if __name__=='__main__':
    main()
