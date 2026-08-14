-- MoneyTrack — SPC-001C — Space-native quick-capture resolvers
-- SOURCE ONLY until controlled runtime apply.
--
-- Text/voice/photo processors must never resolve account/category by legacy
-- user-owned predicates. These boundaries perform all lookups inside one Space.

begin;

create or replace function moneytrack.capture_resolve_account_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_account_hint text,
    p_transaction_type text,
    p_currency_hint text default null,
    p_preferred_account_id bigint default null
)
returns table(
    account_id bigint,
    account_code text,
    account_name text,
    currency_code text,
    status text
)
language plpgsql
stable
as $function$
declare
    v_hint text:=nullif(btrim(p_account_hint),'');
    v_norm_hint text;
    v_currency text:=upper(nullif(btrim(p_currency_hint),''));
    v_preferred bigint:=p_preferred_account_id;
    v_type text:=lower(coalesce(nullif(btrim(p_transaction_type),''),'expense'));
    v_row record;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if v_preferred is null then
        select case when v_type='income' then s.default_income_account_id else s.default_expense_account_id end
          into v_preferred
          from moneytrack.space_financial_settings s
         where s.space_id=p_space_id;
    end if;

    if v_hint is null and v_preferred is not null then
        select a.id,a.code,a.name,a.currency_code
          into v_row
          from moneytrack.accounts a
         where a.id=v_preferred
           and a.space_id=p_space_id
           and coalesce(a.is_active,true)=true
           and (v_currency is null or upper(a.currency_code)=v_currency)
         limit 1;

        if found then
            return query select v_row.id,v_row.code::text,v_row.name::text,
                                upper(v_row.currency_code)::text,'resolved_default'::text;
            return;
        end if;
    end if;

    if v_hint is null then
        return query select null::bigint,null::text,null::text,null::text,'account_not_found'::text;
        return;
    end if;

    v_norm_hint:=lower(regexp_replace(v_hint,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'));

    select a.id,a.code,a.name,a.currency_code
      into v_row
      from moneytrack.accounts a
     where a.space_id=p_space_id
       and coalesce(a.is_active,true)=true
       and (v_currency is null or upper(a.currency_code)=v_currency)
       and (
            lower(a.code)=lower(v_hint)
         or lower(a.name)=lower(v_hint)
         or lower(regexp_replace(a.code,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint
         or lower(regexp_replace(a.name,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint
         or lower(a.code) like '%'||lower(v_hint)||'%'
         or lower(a.name) like '%'||lower(v_hint)||'%'
       )
     order by
       case
         when lower(a.code)=lower(v_hint) then 0
         when lower(a.name)=lower(v_hint) then 1
         when lower(regexp_replace(a.code,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint then 2
         when lower(regexp_replace(a.name,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint then 3
         when lower(a.code) like '%'||lower(v_hint)||'%' then 4
         else 5
       end,
       coalesce(a.sort_order,100),a.id
     limit 1;

    if found then
        return query select v_row.id,v_row.code::text,v_row.name::text,
                            upper(v_row.currency_code)::text,'resolved'::text;
        return;
    end if;

    -- If a name matched only a foreign-currency account, expose a machine code
    -- without returning the foreign account id.
    if v_currency is not null and exists (
        select 1 from moneytrack.accounts a
        where a.space_id=p_space_id
          and coalesce(a.is_active,true)=true
          and (
               lower(a.code)=lower(v_hint)
            or lower(a.name)=lower(v_hint)
            or lower(regexp_replace(a.name,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint
          )
    ) then
        return query select null::bigint,null::text,null::text,null::text,'account_currency_mismatch'::text;
        return;
    end if;

    return query select null::bigint,null::text,null::text,null::text,'account_not_found'::text;
end;
$function$;

comment on function moneytrack.capture_resolve_account_space_v1(bigint,bigint,text,text,text,bigint)
is 'SPC-001 capture account resolver. Lookup/default selection is constrained to the requested Space after active membership; no legacy user_id ownership predicate participates.';


create or replace function moneytrack.capture_resolve_category_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_category_hint text,
    p_flow_type text default null
)
returns table(
    category_id bigint,
    category_code text,
    category_name text,
    flow_type text,
    status text
)
language plpgsql
stable
as $function$
declare
    v_hint text:=nullif(btrim(p_category_hint),'');
    v_norm_hint text;
    v_flow text:=lower(nullif(btrim(p_flow_type),''));
    v_language text;
    v_row record;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if v_hint is null then
        return query select null::bigint,null::text,null::text,null::text,'category_not_provided'::text;
        return;
    end if;
    if v_flow is not null and v_flow not in ('income','expense') then
        raise exception 'CATEGORY_FLOW_INVALID' using errcode='22023';
    end if;

    select coalesce(us.language_code,u.language_code,'en')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id=u.id
     where u.id=p_actor_user_id;

    v_norm_hint:=lower(regexp_replace(v_hint,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'));

    select c.id,c.code,coalesce(tr.name,c.code) as name,c.flow_type
      into v_row
      from moneytrack.category_catalog c
      left join moneytrack.category_catalog_translations tr
        on tr.category_id=c.id
       and tr.language_code=v_language
     where c.space_id=p_space_id
       and coalesce(c.is_active,true)=true
       and (v_flow is null or c.flow_type=v_flow)
       and (
            lower(c.code)=lower(v_hint)
         or lower(coalesce(tr.name,''))=lower(v_hint)
         or lower(regexp_replace(c.code,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint
         or lower(regexp_replace(coalesce(tr.name,''),'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint
         or lower(c.code) like '%'||lower(v_hint)||'%'
         or lower(coalesce(tr.name,'')) like '%'||lower(v_hint)||'%'
       )
     order by
       case
         when lower(c.code)=lower(v_hint) then 0
         when lower(coalesce(tr.name,''))=lower(v_hint) then 1
         when lower(regexp_replace(c.code,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint then 2
         when lower(regexp_replace(coalesce(tr.name,''),'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_norm_hint then 3
         when lower(c.code) like '%'||lower(v_hint)||'%' then 4
         else 5
       end,
       coalesce(c.sort_order,100),c.id
     limit 1;

    if not found then
        return query select null::bigint,null::text,null::text,null::text,'category_not_found'::text;
        return;
    end if;

    return query select v_row.id,v_row.code::text,v_row.name::text,v_row.flow_type::text,'resolved'::text;
end;
$function$;

comment on function moneytrack.capture_resolve_category_space_v1(bigint,bigint,text,text)
is 'SPC-001 capture category resolver. Category code/translation matching is limited to the requested Space and optional income/expense flow.';

commit;
