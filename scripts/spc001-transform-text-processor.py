#!/usr/bin/env python3
"""SPC-001: transform the canonical Text Processor to Space capture boundaries.

The accepted Text/Voice parsing topology is preserved. Runtime-forensic financial
writes, account resolvers and transfer write are replaced with Space-native backend
boundaries. Parse transaction JSON1 is intentionally not guessed here: if it still
contains a tenancy finding, the fail-closed audit prints its full SQL for an exact
follow-up transformation.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

WORKFLOW_ID="f5ioJKyPTupUMV9h"
TARGETS={
    "Resolve text account",
    "Resolve transfer accounts",
    "Insert transfer",
    "Resolve adjustment account",
    "Resolve opening balance account",
    "Insert transaction text",
    "Insert adjustment transaction",
    "Insert opening balance",
}

SOURCE_EXPR="{{ String((($('MoneyTrack Transaction Processor Text').first().json.source_type === 'voice') || ($('MoneyTrack Transaction Processor Text').first().json.message_type === 'voice')) ? 'voice' : 'text').replace(/'/g,\"''\") }}"
REF_EXPR="{{ String($('MoneyTrack Transaction Processor Text').first().json.capture_source_ref || '').replace(/'/g,\"''\") }}"

RESOLVE_TEXT_ACCOUNT_QUERY=r'''select
    r.account_id,
    r.account_code,
    r.account_name,
    r.currency_code,
    r.status
from moneytrack.capture_resolve_account_space_v1(
    {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
    {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
    nullif('{{ String($json.account_hint || '').replace(/'/g,"''") }}','')::text,
    '{{ String($json.operation_type || "expense").replace(/'/g,"''") }}'::text,
    coalesce(
      nullif('{{ String($json.currency || '').replace(/'/g,"''") }}',''),
      nullif('{{ String($json.currency_original || '').replace(/'/g,"''") }}',''),
      nullif('{{ String($json.currency_code || '').replace(/'/g,"''") }}','')
    )::text,
    null
) r;'''

RESOLVE_TRANSFER_ACCOUNTS_QUERY=r'''with parsed as (
    select
        '{{ String($("Parse transaction JSON").first().json.operation_type || "transfer").replace(/'/g,"''") }}'::text as operation_type,
        nullif('{{ String($("Parse transaction JSON").first().json.from_account_hint || '').replace(/'/g,"''") }}','')::text as from_account_hint,
        nullif('{{ String($("Parse transaction JSON").first().json.to_account_hint || '').replace(/'/g,"''") }}','')::text as to_account_hint,
        {{ $("Parse transaction JSON").first().json.amount_from || 0 }}::numeric as amount_from,
        nullif('{{ String($("Parse transaction JSON").first().json.currency_from || '').replace(/'/g,"''") }}','')::text as currency_from,
        {{ $("Parse transaction JSON").first().json.amount_to || $("Parse transaction JSON").first().json.amount_from || 0 }}::numeric as amount_to,
        nullif('{{ String($("Parse transaction JSON").first().json.currency_to || '').replace(/'/g,"''") }}','')::text as currency_to,
        coalesce(
          nullif(nullif('{{ String($("Parse transaction JSON").first().json.transaction_date || '').replace(/'/g,"''") }}',''),'null')::date,
          coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp)::date
        ) as transaction_date
), from_resolved as (
    select r.*
    from parsed p
    cross join lateral moneytrack.capture_resolve_account_space_v1(
        {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
        {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
        p.from_account_hint,
        'transfer'::text,
        p.currency_from,
        null
    ) r
), to_resolved as (
    select r.*
    from parsed p
    cross join lateral moneytrack.capture_resolve_account_space_v1(
        {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
        {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
        p.to_account_hint,
        'transfer'::text,
        p.currency_to,
        null
    ) r
)
select
    f.account_id as from_account_id,
    t.account_id as to_account_id,
    p.amount_from,
    p.amount_to,
    p.transaction_date,
    p.operation_type,
    case
      when f.account_id is null then f.status
      when t.account_id is null then t.status
      when f.account_id=t.account_id then 'same_account'
      else 'resolved'
    end as status
from parsed p
cross join from_resolved f
cross join to_resolved t;'''

INSERT_TRANSFER_QUERY=r'''with r as (
    select
        {{ $("MoneyTrack Transaction Processor Text").first().json.user_id }}::bigint as actor_user_id,
        {{ $("MoneyTrack Transaction Processor Text").first().json.space_id }}::bigint as space_id,
        {{ $("Resolve transfer accounts").first().json.from_account_id || "null" }}::bigint as from_account_id,
        {{ $("Resolve transfer accounts").first().json.to_account_id || "null" }}::bigint as to_account_id,
        {{ $("Resolve transfer accounts").first().json.amount_from || 0 }}::numeric as from_amount,
        {{ $("Resolve transfer accounts").first().json.amount_to || 0 }}::numeric as to_amount,
        '{{ new Date($("Resolve transfer accounts").first().json.transaction_date).toISOString().slice(0,10) }}'::date as transfer_date,
        '{{ String($("Resolve transfer accounts").first().json.operation_type || "transfer").replace(/'/g,"''") }}'::text as transfer_type,
        '{{ String($("Resolve transfer accounts").first().json.status || "").replace(/'/g,"''") }}'::text as status
), created as (
    select c.*
    from (select * from r where status='resolved') rr
    cross join lateral moneytrack.finance_create_transfer_space_v1(
        rr.actor_user_id,
        rr.space_id,
        rr.from_account_id,
        rr.to_account_id,
        rr.from_amount,
        rr.to_amount,
        rr.transfer_date::timestamptz,
        null,
        null,
        null
    ) c
)
select
    r.from_account_id,
    r.to_account_id,
    r.from_amount,
    c.from_currency,
    r.to_amount,
    c.to_currency,
    c.exchange_rate,
    r.transfer_date,
    r.transfer_type,
    c.id,
    case
      when r.status<>'resolved' then r.status
      else 'added'
    end as status
from r
left join created c on true;'''

RESOLVE_ADJUSTMENT_ACCOUNT_QUERY=r'''with parsed as (
    select
        '{{ String($json.operation_type || "adjustment").replace(/'/g,"''") }}'::text as operation_type,
        {{ $json.amount || 0 }}::numeric as amount,
        nullif(nullif('{{ String($json.currency || '').replace(/'/g,"''") }}',''),'null')::text as currency,
        '{{ String($json.description || '').replace(/'/g,"''") }}'::text as description,
        nullif(nullif('{{ String($json.transaction_date || '').replace(/'/g,"''") }}',''),'null')::date as transaction_date,
        nullif('{{ String($json.account_hint || '').replace(/'/g,"''") }}','')::text as account_hint
), resolved as (
    select r.*
    from parsed p
    cross join lateral moneytrack.capture_resolve_account_space_v1(
        {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
        {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
        p.account_hint,
        'adjustment'::text,
        p.currency,
        null
    ) r
)
select
    r.account_id,
    r.account_code,
    r.account_name,
    p.amount,
    coalesce(p.currency,r.currency_code)::text as currency,
    p.description,
    coalesce(p.transaction_date,coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp)::date) as transaction_date,
    r.status
from parsed p
cross join resolved r;'''

RESOLVE_OPENING_BALANCE_ACCOUNT_QUERY=r'''with parsed as (
    select
        {{ $json.amount || 0 }}::numeric as amount,
        nullif(nullif('{{ String($json.currency || '').replace(/'/g,"''") }}',''),'null')::text as currency,
        nullif('{{ String($json.account_hint || '').replace(/'/g,"''") }}','')::text as account_hint,
        coalesce(
          nullif(nullif('{{ String($json.transaction_date || '').replace(/'/g,"''") }}',''),'null')::date,
          coalesce(to_timestamp({{ $('MoneyTrack Transaction Processor Text').first().json.message_date || 'null' }}::double precision),current_timestamp)::date
        ) as transaction_date
), resolved as (
    select r.*
    from parsed p
    cross join lateral moneytrack.capture_resolve_account_space_v1(
        {{ $('MoneyTrack Transaction Processor Text').first().json.user_id }}::bigint,
        {{ $('MoneyTrack Transaction Processor Text').first().json.space_id }}::bigint,
        p.account_hint,
        'openingbalance'::text,
        p.currency,
        null
    ) r
)
select
    r.account_id,
    r.account_code,
    r.account_name,
    p.amount,
    coalesce(p.currency,r.currency_code)::text as currency,
    p.transaction_date,
    r.status
from parsed p
cross join resolved r;'''

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
  "Resolve text account":RESOLVE_TEXT_ACCOUNT_QUERY,
  "Resolve transfer accounts":RESOLVE_TRANSFER_ACCOUNTS_QUERY,
  "Insert transfer":INSERT_TRANSFER_QUERY,
  "Resolve adjustment account":RESOLVE_ADJUSTMENT_ACCOUNT_QUERY,
  "Resolve opening balance account":RESOLVE_OPENING_BALANCE_ACCOUNT_QUERY,
  "Insert transaction text":SIMPLE_QUERY,
  "Insert adjustment transaction":ADJUSTMENT_QUERY,
  "Insert opening balance":OPENING_QUERY,
}

FORBIDDEN_IN_TARGETS=(
  "moneytrack.finance_create_transfer_v1(",
  "moneytrack.user_default_accounts",
  " a.user_id=",
  " a.user_id =",
  " where u.telegram_user_id",
)


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
    for n in out['nodes']:
        if n.get('name') not in TARGETS: continue
        query=str(n.get('parameters',{}).get('query','')).lower()
        for token in FORBIDDEN_IN_TARGETS:
            if token in query:
                raise SystemExit(f"legacy token {token!r} remains in {n.get('name')!r}")
    Path(args.output).write_text(json.dumps([out] if was_array else out,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('SPC-001 Text Processor candidate created')
    print(f'workflow_id={WORKFLOW_ID}')
    print('changed_nodes='+', '.join(sorted(changed)))
    print('financial_tenant=space_id')
    print('account_resolution=SPACE_NATIVE')
    print('transfer_write=finance_create_transfer_space_v1')
    print('capture_source=text_or_voice_from_ingress')
    print('source_ref=required_stable_capture_source_ref')
    print('runtime_mutation=NONE')

if __name__=='__main__': main()
