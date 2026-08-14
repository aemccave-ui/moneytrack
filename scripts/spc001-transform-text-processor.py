#!/usr/bin/env python3
"""SPC-001: transform the canonical Text Processor to Space capture projections.

Input is the already accepted BE-DOM-001/UX-024 Text Processor candidate. Only
its three named financial write nodes are replaced. Parsing/account resolution
stays unchanged; DB tenancy/authorship moves to capture_create_projection_compat_v1.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID="f5ioJKyPTupUMV9h"
TARGETS={"Insert transaction text","Insert adjustment transaction","Insert opening balance"}

SOURCE_EXPR="{{ String((($('MoneyTrack Transaction Processor Text').first().json.source_type === 'voice') || ($('MoneyTrack Transaction Processor Text').first().json.message_type === 'voice')) ? 'voice' : 'text').replace(/'/g,\"''\") }}"
REF_EXPR="{{ String($('MoneyTrack Transaction Processor Text').first().json.capture_source_ref || '').replace(/'/g,\"''\") }}"

SIMPLE_QUERY=r'''select
    c.id,
    c.account_id,
    c.capture_event_id,
    c.idempotent_replay
from moneytrack.capture_create_projection_compat_v1(
    {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
    '__SOURCE__'::text,
    '__REF__'::text,
    {{ $json.account_id }}::bigint,
    '{{ String($("Parse transaction JSON").item.json.operation_type || "").replace(/'/g,"''") }}'::text,
    {{ $("Parse transaction JSON").item.json.amount }}::numeric,
    '{{ String($("Parse transaction JSON").item.json.currency || "").replace(/'/g,"''") }}'::text,
    '{{ String($("Parse transaction JSON").item.json.description || "").replace(/'/g,"''") }}'::text,
    case
      when nullif(nullif('{{ $("Parse transaction JSON").item.json.transaction_date }}','null'),'undefined') is not null
      then (
        nullif(nullif('{{ $("Parse transaction JSON").item.json.transaction_date }}','null'),'undefined')::date::text
        || ' ' || to_char(coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp),'HH24:MI:SS')
      )::timestamp::timestamptz
      else coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp)
    end,
    null
) c;'''.replace('__SOURCE__',SOURCE_EXPR).replace('__REF__',REF_EXPR)

ADJUSTMENT_QUERY=r'''select
    c.id,
    c.capture_event_id,
    c.idempotent_replay
from moneytrack.capture_create_projection_compat_v1(
    {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
    '__SOURCE__'::text,
    '__REF__'::text,
    {{ $json.account_id }}::bigint,
    'adjustment'::text,
    {{ $json.amount }}::numeric,
    '{{ String($json.currency || "").replace(/'/g,"''") }}'::text,
    '{{ String($json.description || "").replace(/'/g,"''") }}'::text,
    case
      when nullif(nullif('{{ $json.transaction_date }}','null'),'undefined') is not null
      then (
        nullif(nullif('{{ $json.transaction_date }}','null'),'undefined')::date::text
        || ' ' || to_char(coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp),'HH24:MI:SS')
      )::timestamp::timestamptz
      else coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp)
    end,
    null
) c;'''.replace('__SOURCE__',SOURCE_EXPR).replace('__REF__',REF_EXPR)

OPENING_QUERY=r'''with r as (
    select
      {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint as actor_user_id,
      {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint as space_id,
      {{ $('Resolve opening balance account').first().json.account_id || "null" }}::bigint as account_id,
      {{ $('Resolve opening balance account').first().json.amount || 0 }}::numeric as amount,
      '{{ String($('Resolve opening balance account').first().json.currency || "").replace(/'/g,"''") }}'::text as currency,
      '{{ new Date($('Resolve opening balance account').first().json.transaction_date).toISOString().slice(0,10) }}'::date as transaction_date,
      '{{ String($('Resolve opening balance account').first().json.status || "").replace(/'/g,"''") }}'::text as resolve_status
), existing as (
    select t.id
    from r
    join moneytrack.transactions t
      on t.space_id=r.space_id
     and t.account_id=r.account_id
     and t.transaction_type='openingbalance'
    where r.resolve_status='resolved'
    order by t.id
    limit 1
), created as (
    select c.*
    from r
    where r.resolve_status='resolved'
      and not exists(select 1 from existing)
    cross join lateral moneytrack.capture_create_projection_compat_v1(
      r.actor_user_id,r.space_id,'__SOURCE__'::text,'__REF__'::text,
      r.account_id,'openingbalance',r.amount,r.currency,'opening balance',r.transaction_date::timestamptz,null
    ) c
)
select
    r.account_id,r.amount,r.currency,r.transaction_date,r.resolve_status,
    coalesce(e.id,c.id) as id,
    case
      when r.resolve_status<>'resolved' then r.resolve_status
      when e.id is not null then 'already_exists'
      when c.idempotent_replay then 'already_exists'
      else 'added'
    end as status,
    c.capture_event_id
from r
left join existing e on true
left join created c on true;'''.replace('__SOURCE__',SOURCE_EXPR).replace('__REF__',REF_EXPR)

REPLACEMENTS={
  "Insert transaction text":SIMPLE_QUERY,
  "Insert adjustment transaction":ADJUSTMENT_QUERY,
  "Insert opening balance":OPENING_QUERY,
}


def unwrap(doc):
    if isinstance(doc,list):
        if len(doc)!=1: raise SystemExit(f"expected one workflow, got {len(doc)}")
        return doc[0],True
    if isinstance(doc,dict): return doc,False
    raise SystemExit("input must be workflow object or one-element array")


def main():
    ap=argparse.ArgumentParser();ap.add_argument('input');ap.add_argument('output');args=ap.parse_args()
    src=json.loads(Path(args.input).read_text(encoding='utf-8'));wf,was_array=unwrap(src)
    if wf.get('id')!=WORKFLOW_ID: raise SystemExit(f"unexpected workflow id: {wf.get('id')!r}")
    found={n.get('name') for n in wf.get('nodes',[]) if n.get('name') in TARGETS}
    if found!=TARGETS: raise SystemExit(f"target mismatch: found={sorted(found)} expected={sorted(TARGETS)}")
    out=copy.deepcopy(wf);changed=[]
    for n in out['nodes']:
        name=n.get('name')
        if name in REPLACEMENTS:
            p=n.setdefault('parameters',{})
            if p.get('operation')!='executeQuery': raise SystemExit(f"{name!r} is not executeQuery")
            p['query']=REPLACEMENTS[name];changed.append(name)
    if set(changed)!=TARGETS: raise SystemExit(f"changed mismatch: {sorted(changed)}")
    Path(args.output).write_text(json.dumps([out] if was_array else out,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('SPC-001 Text Processor candidate created')
    print(f'workflow_id={WORKFLOW_ID}')
    print('changed_nodes='+', '.join(sorted(changed)))
    print('financial_tenant=space_id')
    print('capture_source=text_or_voice_from_ingress')
    print('source_ref=required_stable_capture_source_ref')

if __name__=='__main__': main()
