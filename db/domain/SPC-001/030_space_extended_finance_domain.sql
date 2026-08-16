-- MoneyTrack — SPC-001A/B — extended Space-native finance API domain
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- These boundaries replace the remaining UX-022/023 user-owned API surfaces.
-- Every financial read/write asserts current membership and scopes by space_id.
-- user_id is actor/provenance only and is never used as the financial tenant.

begin;

-- ---------------------------------------------------------------------------
-- Reference data: currencies are global; categories are Space-owned.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.finance_transaction_reference_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns table(currencies jsonb,categories jsonb)
language plpgsql
stable
as $function$
declare
    v_language text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select coalesce(us.language_code,u.language_code,'en')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id=u.id
     where u.id=p_actor_user_id;

    return query
    select
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'code',c.code,
          'name',c.name,
          'symbol',c.symbol
        ) order by c.code)
        from moneytrack.currencies c
      ),'[]'::jsonb),
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',c.id,
          'code',c.code,
          'name',coalesce(tr.name,c.code),
          'parent_id',c.parent_id,
          'is_active',coalesce(c.is_active,true),
          'sort_order',c.sort_order,
          'flow_type',c.flow_type,
          'editable',true
        ) order by c.sort_order,c.id)
        from moneytrack.category_catalog c
        left join moneytrack.category_catalog_translations tr
          on tr.category_id=c.id and tr.language_code=v_language
        where c.space_id=p_space_id
          and coalesce(c.is_active,true)=true
      ),'[]'::jsonb);
end;
$function$;

-- ---------------------------------------------------------------------------
-- Filter presets are USER_SPACE_PREFERENCE: same user may have independent
-- presets in several Spaces; every referenced financial id must be Space-local.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.filter_presets_space_read_v1(
    p_actor_user_id bigint,p_space_id bigint
)
returns table(presets jsonb)
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    return query
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',p.id,'name',p.name,'account_ids',p.account_ids,
      'income_category_ids',p.income_category_ids,
      'expense_category_ids',p.expense_category_ids,'created_at',p.created_at
    ) order by p.created_at,p.id),'[]'::jsonb)
    from moneytrack.filter_presets p
    where p.user_id=p_actor_user_id and p.space_id=p_space_id;
end;
$function$;

create or replace function moneytrack.filter_preset_create_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_name text,
    p_account_ids bigint[],p_income_category_ids bigint[],p_expense_category_ids bigint[]
)
returns table(preset jsonb)
language plpgsql
volatile
as $function$
declare
    v_name text:=nullif(btrim(p_name),'');
    v_accounts bigint[]:=coalesce(p_account_ids,'{}'::bigint[]);
    v_income bigint[]:=coalesce(p_income_category_ids,'{}'::bigint[]);
    v_expense bigint[]:=coalesce(p_expense_category_ids,'{}'::bigint[]);
    v_row moneytrack.filter_presets%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if v_name is null or char_length(v_name)>80 then raise exception 'PRESET_NAME_INVALID' using errcode='22023'; end if;

    if exists (
      select 1 from unnest(v_accounts) x(id)
      where not exists (select 1 from moneytrack.accounts a where a.id=x.id and a.space_id=p_space_id and coalesce(a.is_active,true)=true)
    ) then raise exception 'ACCOUNT_IDS_INVALID' using errcode='22023'; end if;

    if exists (
      select 1 from unnest(v_income||v_expense) x(id)
      where not exists (select 1 from moneytrack.category_catalog c where c.id=x.id and c.space_id=p_space_id and coalesce(c.is_active,true)=true)
    ) then raise exception 'CATEGORY_IDS_INVALID' using errcode='22023'; end if;

    select coalesce(array_agg(distinct id order by id),'{}'::bigint[]) into v_accounts from unnest(v_accounts) x(id);
    select coalesce(array_agg(distinct id order by id),'{}'::bigint[]) into v_income from unnest(v_income) x(id);
    select coalesce(array_agg(distinct id order by id),'{}'::bigint[]) into v_expense from unnest(v_expense) x(id);

    insert into moneytrack.filter_presets(user_id,space_id,name,account_ids,income_category_ids,expense_category_ids,created_at)
    values(p_actor_user_id,p_space_id,v_name,v_accounts,v_income,v_expense,now()) returning * into v_row;

    return query select jsonb_build_object(
      'id',v_row.id,'name',v_row.name,'account_ids',v_row.account_ids,
      'income_category_ids',v_row.income_category_ids,'expense_category_ids',v_row.expense_category_ids,
      'created_at',v_row.created_at
    );
end;
$function$;

create or replace function moneytrack.filter_preset_rename_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_preset_id bigint,p_name text
)
returns table(preset jsonb)
language plpgsql
volatile
as $function$
declare v_row moneytrack.filter_presets%rowtype; v_name text:=nullif(btrim(p_name),'');
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if v_name is null or char_length(v_name)>80 then raise exception 'PRESET_NAME_INVALID' using errcode='22023'; end if;
    update moneytrack.filter_presets p set name=v_name
     where p.id=p_preset_id and p.user_id=p_actor_user_id and p.space_id=p_space_id
     returning * into v_row;
    if not found then raise exception 'PRESET_NOT_FOUND' using errcode='P0002'; end if;
    return query select jsonb_build_object(
      'id',v_row.id,'name',v_row.name,'account_ids',v_row.account_ids,
      'income_category_ids',v_row.income_category_ids,'expense_category_ids',v_row.expense_category_ids,
      'created_at',v_row.created_at
    );
end;
$function$;

create or replace function moneytrack.filter_preset_delete_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_preset_id bigint
)
returns table(deleted_id bigint)
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    return query delete from moneytrack.filter_presets p
      where p.id=p_preset_id and p.user_id=p_actor_user_id and p.space_id=p_space_id
      returning p.id;
    if not found then raise exception 'PRESET_NOT_FOUND' using errcode='P0002'; end if;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Account lifecycle. All members have the same financial CRUD rights.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.account_create_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_name text,p_account_type text,
    p_currency_code text,p_parent_id bigint default null,p_code text default null
)
returns table(account jsonb)
language plpgsql
volatile
as $function$
declare
    v_id bigint; v_code text; v_name text:=nullif(btrim(p_name),'');
    v_currency text:=upper(nullif(btrim(p_currency_code),''));
    v_type text:=coalesce(nullif(btrim(p_account_type),''),'cash');
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if v_name is null then raise exception 'ACCOUNT_NAME_REQUIRED' using errcode='22023'; end if;
    if not exists(select 1 from moneytrack.currencies c where c.code=v_currency) then raise exception 'ACCOUNT_CURRENCY_INVALID' using errcode='22023'; end if;
    if p_parent_id is not null and not exists(select 1 from moneytrack.accounts a where a.id=p_parent_id and a.space_id=p_space_id) then raise exception 'PARENT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    v_code:=coalesce(nullif(btrim(p_code),''),'account_'||substr(md5(random()::text||clock_timestamp()::text),1,12));
    insert into moneytrack.accounts(user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,created_by_user_id,updated_by_user_id)
    values(p_actor_user_id,p_space_id,v_code,v_name,v_type,v_currency,true,now(),100,p_parent_id,p_actor_user_id,p_actor_user_id)
    returning id into v_id;

    return query select jsonb_build_object('id',a.id,'code',a.code,'name',a.name,'account_type',a.account_type,'currency_code',a.currency_code,'parent_id',a.parent_id,'is_active',a.is_active)
    from moneytrack.accounts a where a.id=v_id;
end;
$function$;

create or replace function moneytrack.account_edit_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_account_id bigint,p_name text,p_account_type text
)
returns table(account jsonb)
language plpgsql
volatile
as $function$
declare v_row moneytrack.accounts%rowtype; v_name text:=nullif(btrim(p_name),'');
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if v_name is null then raise exception 'ACCOUNT_NAME_REQUIRED' using errcode='22023'; end if;
    update moneytrack.accounts a set name=v_name,account_type=coalesce(nullif(btrim(p_account_type),''),a.account_type),updated_by_user_id=p_actor_user_id
     where a.id=p_account_id and a.space_id=p_space_id returning * into v_row;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    return query select jsonb_build_object('id',v_row.id,'code',v_row.code,'name',v_row.name,'account_type',v_row.account_type,'currency_code',v_row.currency_code,'parent_id',v_row.parent_id,'is_active',v_row.is_active);
end;
$function$;

create or replace function moneytrack.account_copy_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_account_id bigint
)
returns table(account jsonb)
language plpgsql
volatile
as $function$
declare v_src moneytrack.accounts%rowtype; v_id bigint; v_code text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select * into v_src from moneytrack.accounts a where a.id=p_account_id and a.space_id=p_space_id;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    v_code:=left(v_src.code||'_copy_'||substr(md5(clock_timestamp()::text||random()::text),1,8),120);
    insert into moneytrack.accounts(user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,created_by_user_id,updated_by_user_id)
    values(p_actor_user_id,p_space_id,v_code,v_src.name||' copy',v_src.account_type,v_src.currency_code,true,now(),v_src.sort_order,v_src.parent_id,p_actor_user_id,p_actor_user_id)
    returning id into v_id;
    return query select jsonb_build_object('id',a.id,'code',a.code,'name',a.name,'account_type',a.account_type,'currency_code',a.currency_code,'parent_id',a.parent_id,'is_active',a.is_active)
      from moneytrack.accounts a where a.id=v_id;
end;
$function$;

create or replace function moneytrack.account_move_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_account_id bigint,p_parent_id bigint
)
returns table(account_id bigint,previous_parent_id bigint,parent_id bigint,status text)
language plpgsql
volatile
as $function$
declare v_previous bigint;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select a.parent_id into v_previous from moneytrack.accounts a where a.id=p_account_id and a.space_id=p_space_id for update;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    if p_parent_id=p_account_id then raise exception 'ACCOUNT_PARENT_CYCLE' using errcode='22023'; end if;
    if p_parent_id is not null and not exists(select 1 from moneytrack.accounts a where a.id=p_parent_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true) then raise exception 'PARENT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    if p_parent_id is not null and exists(
      with recursive d(id) as (
        select a.id from moneytrack.accounts a where a.parent_id=p_account_id and a.space_id=p_space_id
        union all select a.id from moneytrack.accounts a join d on a.parent_id=d.id where a.space_id=p_space_id
      ) select 1 from d where id=p_parent_id
    ) then raise exception 'ACCOUNT_PARENT_CYCLE' using errcode='22023'; end if;
    update moneytrack.accounts set parent_id=p_parent_id,updated_by_user_id=p_actor_user_id where id=p_account_id and space_id=p_space_id;
    return query select p_account_id,v_previous,p_parent_id,'moved'::text;
end;
$function$;

create or replace function moneytrack.account_archive_space_v1(p_actor_user_id bigint,p_space_id bigint,p_account_id bigint)
returns table(account_id bigint,status text)
language plpgsql volatile as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    update moneytrack.accounts set is_active=false,updated_by_user_id=p_actor_user_id where id=p_account_id and space_id=p_space_id;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    return query select p_account_id,'archived'::text;
end;$function$;

create or replace function moneytrack.account_restore_space_v1(p_actor_user_id bigint,p_space_id bigint,p_account_id bigint)
returns table(account_id bigint,status text)
language plpgsql volatile as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    update moneytrack.accounts set is_active=true,updated_by_user_id=p_actor_user_id where id=p_account_id and space_id=p_space_id;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    return query select p_account_id,'restored'::text;
end;$function$;

create or replace function moneytrack.accounts_archived_space_read_v1(p_actor_user_id bigint,p_space_id bigint)
returns table(accounts jsonb)
language plpgsql stable as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    return query select coalesce(jsonb_agg(jsonb_build_object(
      'id',a.id,'code',a.code,'name',a.name,'account_type',a.account_type,'currency_code',a.currency_code,'parent_id',a.parent_id,'is_active',a.is_active
    ) order by a.sort_order,a.id),'[]'::jsonb)
    from moneytrack.accounts a where a.space_id=p_space_id and coalesce(a.is_active,true)=false;
end;$function$;

create or replace function moneytrack.account_move_operations_preview_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_source_account_id bigint,p_target_account_id bigint
)
returns table(source_account_id bigint,target_account_id bigint,currency_code text,operation_count bigint,transfer_count bigint,collapsing_transfer_count bigint,opening_balance_conflict boolean)
language plpgsql stable as $function$
declare v_currency text; v_target_currency text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select a.currency_code into v_currency from moneytrack.accounts a where a.id=p_source_account_id and a.space_id=p_space_id;
    select a.currency_code into v_target_currency from moneytrack.accounts a where a.id=p_target_account_id and a.space_id=p_space_id;
    if v_currency is null or v_target_currency is null then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    if v_currency<>v_target_currency then raise exception 'ACCOUNT_CURRENCY_MISMATCH' using errcode='22023'; end if;
    return query select p_source_account_id,p_target_account_id,v_currency,
      (select count(*) from moneytrack.transactions t where t.space_id=p_space_id and t.account_id=p_source_account_id),
      (select count(*) from moneytrack.transfers t where t.space_id=p_space_id and (t.from_account_id=p_source_account_id or t.to_account_id=p_source_account_id)),
      (select count(*) from moneytrack.transfers t where t.space_id=p_space_id and ((t.from_account_id=p_source_account_id and t.to_account_id=p_target_account_id) or (t.to_account_id=p_source_account_id and t.from_account_id=p_target_account_id))),
      exists(select 1 from moneytrack.transactions t where t.space_id=p_space_id and t.account_id=p_target_account_id and t.transaction_type='openingbalance');
end;$function$;

create or replace function moneytrack.account_move_operations_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_source_account_id bigint,p_target_account_id bigint
)
returns table(operation_count bigint,transfer_count bigint,status text)
language plpgsql volatile as $function$
declare v_preview record; v_ops bigint; v_trans bigint;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select * into v_preview from moneytrack.account_move_operations_preview_space_v1(p_actor_user_id,p_space_id,p_source_account_id,p_target_account_id);
    if v_preview.opening_balance_conflict then raise exception 'OPENING_BALANCE_CONFLICT' using errcode='23505'; end if;
    if v_preview.collapsing_transfer_count>0 then raise exception 'COLLAPSING_TRANSFER_CONFLICT' using errcode='23505'; end if;
    update moneytrack.transactions set account_id=p_target_account_id,updated_by_user_id=p_actor_user_id where space_id=p_space_id and account_id=p_source_account_id;
    get diagnostics v_ops=row_count;
    update moneytrack.transfers set from_account_id=p_target_account_id,updated_by_user_id=p_actor_user_id where space_id=p_space_id and from_account_id=p_source_account_id;
    get diagnostics v_trans=row_count;
    update moneytrack.transfers set to_account_id=p_target_account_id,updated_by_user_id=p_actor_user_id where space_id=p_space_id and to_account_id=p_source_account_id;
    v_trans:=v_trans+row_count;
    return query select v_ops,v_trans,'moved'::text;
end;$function$;

create or replace function moneytrack.account_delete_space_v1(p_actor_user_id bigint,p_space_id bigint,p_account_id bigint)
returns table(deleted_id bigint,status text)
language plpgsql volatile as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if exists(select 1 from moneytrack.accounts a where a.space_id=p_space_id and a.parent_id=p_account_id) then raise exception 'ACCOUNT_HAS_CHILDREN' using errcode='23503'; end if;
    if exists(select 1 from moneytrack.transactions t where t.space_id=p_space_id and t.account_id=p_account_id) or exists(select 1 from moneytrack.transfers t where t.space_id=p_space_id and (t.from_account_id=p_account_id or t.to_account_id=p_account_id)) then raise exception 'ACCOUNT_HAS_OPERATIONS' using errcode='23503'; end if;
    delete from moneytrack.space_default_accounts d where d.space_id=p_space_id and d.account_id=p_account_id;
    delete from moneytrack.accounts a where a.id=p_account_id and a.space_id=p_space_id returning a.id into deleted_id;
    if deleted_id is null then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    status:='deleted'; return next;
end;$function$;

-- ---------------------------------------------------------------------------
-- Transfer editor; the entire transfer is inside exactly one Space.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.finance_get_transfer_space_v1(p_actor_user_id bigint,p_space_id bigint,p_transfer_id bigint)
returns table(id bigint,space_id bigint,from_account_id bigint,from_account_name text,to_account_id bigint,to_account_name text,from_amount numeric,from_currency text,to_amount numeric,to_currency text,exchange_rate numeric,transfer_date timestamptz,transfer_type text,created_by_user_id bigint,updated_by_user_id bigint)
language plpgsql stable as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    return query select t.id,t.space_id,t.from_account_id,af.name::text,t.to_account_id,at.name::text,t.from_amount,t.from_currency::text,t.to_amount,t.to_currency::text,t.exchange_rate,t.transfer_date,coalesce(t.transfer_type,'transfer')::text,t.created_by_user_id,t.updated_by_user_id
      from moneytrack.transfers t join moneytrack.accounts af on af.id=t.from_account_id and af.space_id=t.space_id join moneytrack.accounts at on at.id=t.to_account_id and at.space_id=t.space_id
     where t.id=p_transfer_id and t.space_id=p_space_id limit 1;
    if not found then raise exception 'TRANSFER_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
end;$function$;

create or replace function moneytrack.finance_update_transfer_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_transfer_id bigint,p_from_account_id bigint,p_to_account_id bigint,p_from_amount numeric,p_transfer_date timestamptz,p_transfer_type text default null
)
returns moneytrack.transfers
language plpgsql volatile as $function$
declare v_existing moneytrack.transfers%rowtype; v_from text; v_to text; v_to_amount numeric; v_rate numeric; v_type text; v_row moneytrack.transfers%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select * into v_existing from moneytrack.transfers t where t.id=p_transfer_id and t.space_id=p_space_id for update;
    if not found then raise exception 'TRANSFER_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    if p_from_account_id=p_to_account_id then raise exception 'SAME_ACCOUNT_TRANSFER_FORBIDDEN' using errcode='22023'; end if;
    if p_from_amount is null or p_from_amount<=0 or p_transfer_date is null then raise exception 'INVALID_TRANSFER_INPUT' using errcode='22023'; end if;
    select upper(a.currency_code) into v_from from moneytrack.accounts a where a.id=p_from_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true;
    select upper(a.currency_code) into v_to from moneytrack.accounts a where a.id=p_to_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true;
    if v_from is null or v_to is null then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    v_type:=coalesce(nullif(btrim(p_transfer_type),''),nullif(btrim(v_existing.transfer_type),''),'transfer');
    if v_from=v_to then v_type:='transfer';v_to_amount:=p_from_amount;v_rate:=1;
    else
      if v_type='transfer' then v_type:='transferexchange'; end if;
      v_to_amount:=moneytrack.finance_fx_convert_usd_bridge_v1(p_from_amount,v_from,v_to,p_transfer_date::date);
      if v_to_amount is null or v_to_amount<=0 then raise exception 'FX_CONVERSION_UNAVAILABLE' using errcode='P0001'; end if;
      v_rate:=v_to_amount/p_from_amount;
    end if;
    update moneytrack.transfers set from_account_id=p_from_account_id,to_account_id=p_to_account_id,from_amount=p_from_amount,from_currency=v_from,to_amount=v_to_amount,to_currency=v_to,exchange_rate=v_rate,transfer_date=p_transfer_date,transfer_type=v_type,updated_by_user_id=p_actor_user_id
     where id=p_transfer_id and space_id=p_space_id returning * into v_row;
    return v_row;
end;$function$;

create or replace function moneytrack.finance_delete_transfer_space_v1(p_actor_user_id bigint,p_space_id bigint,p_transfer_id bigint)
returns table(id bigint)
language plpgsql volatile as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    return query delete from moneytrack.transfers t where t.id=p_transfer_id and t.space_id=p_space_id returning t.id;
    if not found then raise exception 'TRANSFER_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
end;$function$;

-- ---------------------------------------------------------------------------
-- Category mutation is Space-local. Global templates are immutable here.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.category_update_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_category_id bigint,p_name text,p_flow_type text
)
returns table(category jsonb)
language plpgsql volatile as $function$
declare v_lang text; v_name text:=nullif(btrim(p_name),''); v_flow text:=lower(nullif(btrim(p_flow_type),''));
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if v_name is null or v_flow not in ('income','expense') then raise exception 'CATEGORY_INPUT_INVALID' using errcode='22023'; end if;
    if not exists(select 1 from moneytrack.category_catalog c where c.id=p_category_id and c.space_id=p_space_id) then raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    update moneytrack.category_catalog set flow_type=v_flow,updated_by_user_id=p_actor_user_id where id=p_category_id and space_id=p_space_id;
    select coalesce(us.language_code,u.language_code,'en') into v_lang from moneytrack.app_users u left join moneytrack.user_settings us on us.user_id=u.id where u.id=p_actor_user_id;
    insert into moneytrack.category_catalog_translations(category_id,language_code,name) values(p_category_id,v_lang,v_name)
    on conflict(category_id,language_code) do update set name=excluded.name;
    return query select jsonb_build_object('id',c.id,'code',c.code,'name',v_name,'parent_id',c.parent_id,'flow_type',c.flow_type,'editable',true)
      from moneytrack.category_catalog c where c.id=p_category_id;
end;$function$;

-- ---------------------------------------------------------------------------
-- Receipt API compatibility over SPC capture/projection model.
-- Parser facts stay immutable; accounting/category changes mutate only the
-- current Space projection.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.receipt_projection_api_read_v1(
    p_actor_user_id bigint,p_space_id bigint,p_transaction_id bigint
)
returns jsonb
language plpgsql stable as $function$
declare v_result jsonb;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select jsonb_build_object(
      'id',cr.id,'transaction_id',t.id,'space_id',t.space_id,
      'shop_name',cr.merchant,'receipt_date',cr.recognized_at,'transaction_date',t.transaction_date,
      'total_amount',cr.total_amount,'currency',t.currency_original,
      'recognized_currency',cr.currency,'account_id',t.account_id,'account_name',a.name,
      'items',coalesce((select jsonb_agg(jsonb_build_object(
        'id',cri.id,'description',cri.item_name_original,'item_name_original',cri.item_name_original,
        'item_language',cri.item_language,'quantity',cri.quantity,'unit_price',cri.unit_price,'amount',cri.amount,
        'category_id',pc.category_id,'category_name',coalesce(tr.name,cat.code),'category_code',cat.code,'product_id',pc.product_id
      ) order by cri.id)
      from moneytrack.capture_receipt_items cri
      left join moneytrack.receipt_item_projection_classification pc on pc.transaction_id=t.id and pc.capture_receipt_item_id=cri.id
      left join moneytrack.category_catalog cat on cat.id=pc.category_id and cat.space_id=t.space_id
      left join moneytrack.user_settings us on us.user_id=p_actor_user_id
      left join moneytrack.app_users au on au.id=p_actor_user_id
      left join moneytrack.category_catalog_translations tr on tr.category_id=cat.id and tr.language_code=coalesce(us.language_code,au.language_code,'en')
      where cri.capture_receipt_id=cr.id),'[]'::jsonb)
    ) into v_result
    from moneytrack.transactions t
    join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
    join moneytrack.capture_receipts cr on cr.capture_event_id=t.capture_event_id
    where t.id=p_transaction_id and t.space_id=p_space_id;
    if v_result is null then raise exception 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    return v_result;
end;$function$;

create or replace function moneytrack.receipt_projection_accounting_update_v1(
    p_actor_user_id bigint,p_space_id bigint,p_capture_receipt_id bigint,p_account_id bigint,p_currency text
)
returns jsonb
language plpgsql volatile as $function$
declare v_tx moneytrack.transactions%rowtype; v_updated moneytrack.transactions%rowtype; v_currency text:=upper(nullif(btrim(p_currency),'')); v_account_name text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select t.* into v_tx from moneytrack.capture_receipts cr join moneytrack.transactions t on t.capture_event_id=cr.capture_event_id
     where cr.id=p_capture_receipt_id and t.space_id=p_space_id limit 1 for update of t;
    if not found then raise exception 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    select a.name into v_account_name from moneytrack.accounts a where a.id=p_account_id and a.space_id=p_space_id and upper(a.currency_code)=v_currency and coalesce(a.is_active,true)=true;
    if v_account_name is null then raise exception 'ACCOUNT_CURRENCY_MISMATCH' using errcode='22023'; end if;
    v_updated:=moneytrack.finance_update_transaction_space_v1(p_actor_user_id,p_space_id,v_tx.id,p_account_id,v_tx.transaction_type,v_tx.amount_original,v_currency,v_tx.description,v_tx.transaction_date,v_tx.category_id);
    return jsonb_build_object('receipt_id',p_capture_receipt_id,'transaction_id',v_updated.id,'account_id',p_account_id,'account_name',v_account_name,'currency',v_currency,'account_currency',v_currency);
end;$function$;

create or replace function moneytrack.receipt_item_projection_set_category_by_item_v1(
    p_actor_user_id bigint,p_space_id bigint,p_capture_receipt_item_id bigint,p_category_id bigint
)
returns jsonb
language plpgsql volatile as $function$
declare v_tx_id bigint; v_name text; v_code text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select t.id into v_tx_id
      from moneytrack.capture_receipt_items cri
      join moneytrack.capture_receipts cr on cr.id=cri.capture_receipt_id
      join moneytrack.transactions t on t.capture_event_id=cr.capture_event_id and t.space_id=p_space_id
     where cri.id=p_capture_receipt_item_id limit 1;
    if v_tx_id is null then raise exception 'RECEIPT_ITEM_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    perform moneytrack.receipt_projection_set_classification_v1(p_actor_user_id,p_space_id,v_tx_id,p_capture_receipt_item_id,p_category_id,null);
    if p_category_id is not null then
      select c.code,coalesce(tr.name,c.code) into v_code,v_name
      from moneytrack.category_catalog c
      left join moneytrack.user_settings us on us.user_id=p_actor_user_id
      left join moneytrack.app_users u on u.id=p_actor_user_id
      left join moneytrack.category_catalog_translations tr on tr.category_id=c.id and tr.language_code=coalesce(us.language_code,u.language_code,'en')
      where c.id=p_category_id and c.space_id=p_space_id;
    end if;
    return jsonb_build_object('receipt_item_id',p_capture_receipt_item_id,'category_id',p_category_id,'category_name',v_name,'category_code',v_code);
end;$function$;

-- ---------------------------------------------------------------------------
-- Account-filtered transaction/explorer reads for UX-022.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.api_transactions_space_read_model_v1(
    p_actor_user_id bigint,p_space_id bigint,p_account_id bigint,p_date_from date,p_date_to date,
    p_include_descendants boolean default true,p_selected_account_ids bigint[] default null,
    p_income_category_ids bigint[] default null,p_expense_category_ids bigint[] default null
)
returns table(actor_user_id bigint,space_id bigint,base_currency text,summary_currency text,income numeric,expense numeric,result numeric,transfers numeric,count bigint,missing_rate_count bigint,transactions jsonb)
language plpgsql stable as $function$
declare v_base text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select s.base_currency into v_base from moneytrack.space_financial_settings s where s.space_id=p_space_id;
    return query
    with recursive descendants(id) as (
      select a.id from moneytrack.accounts a where a.id=p_account_id and a.space_id=p_space_id
      union all select a.id from moneytrack.accounts a join descendants d on a.parent_id=d.id where a.space_id=p_space_id
    ), scope as (
      select id from descendants where p_include_descendants
      union select p_account_id where not p_include_descendants
    ), chosen as (
      select id from scope where p_selected_account_ids is null
      union select unnest(p_selected_account_ids) where p_selected_account_ids is not null
    ), tx as (
      select t.*,a.name as account_name,
        case when coalesce(nullif(t.currency_original,''),a.currency_code,v_base)=v_base then abs(coalesce(t.amount_original,0))
             else moneytrack.finance_fx_convert_usd_bridge_v1(abs(coalesce(t.amount_original,0)),coalesce(nullif(t.currency_original,''),a.currency_code,v_base),v_base,t.transaction_date::date) end as amount_effective
      from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
      where t.space_id=p_space_id and t.account_id in(select id from chosen)
        and t.transaction_date>=p_date_from and t.transaction_date<(p_date_to+1)::date
        and (t.transaction_type<>'income' or p_income_category_ids is null or t.category_id=any(p_income_category_ids))
        and (t.transaction_type<>'expense' or p_expense_category_ids is null or t.category_id=any(p_expense_category_ids))
    ), sums as (
      select coalesce(sum(case when transaction_type='income' then amount_effective else 0 end),0) as income,
             coalesce(sum(case when transaction_type='expense' then amount_effective else 0 end),0) as expense,
             count(*)::bigint as count,
             count(*) filter(where amount_effective is null)::bigint as missing
      from tx
    )
    select p_actor_user_id,p_space_id,v_base,v_base,s.income,s.expense,s.income-s.expense,0::numeric,s.count,s.missing,
      coalesce((select jsonb_agg(jsonb_build_object(
        'id',x.id,'transaction_type',x.transaction_type,'account_id',x.account_id,'account_name',x.account_name,
        'amount_original',x.amount_original,'amount_base',x.amount_base,'currency_original',x.currency_original,
        'category_id',x.category_id,'description',x.description,'transaction_date',x.transaction_date,
        'source_type',x.source_type,'source_kind',x.source_type,'created_by_user_id',x.created_by_user_id,'capture_event_id',x.capture_event_id
      ) order by x.transaction_date desc,x.id desc) from tx x),'[]'::jsonb)
    from sums s;
end;$function$;

create or replace function moneytrack.api_accounts_explorer_summary_space_v1(
    p_actor_user_id bigint,p_space_id bigint,p_selected_account_ids bigint[],p_income_category_ids bigint[],p_expense_category_ids bigint[],p_date_from date,p_date_to date,p_as_of date
)
returns table(actor_user_id bigint,space_id bigint,base_currency text,total_base numeric,account_balances jsonb,snapshot_missing_rate_count bigint,period_income numeric,period_expense numeric,period_result numeric,period_count bigint,date_from date,date_to date)
language plpgsql stable as $function$
declare v_base text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    select s.base_currency into v_base from moneytrack.space_financial_settings s where s.space_id=p_space_id;
    return query
    with chosen as (select unnest(coalesce(p_selected_account_ids,'{}'::bigint[])) id),
    balances as (
      select a.id,a.name,a.currency_code,
       coalesce(sum(case when t.transaction_type='expense' then -abs(t.amount_original) else t.amount_original end),0)
       +coalesce((select sum(tr.to_amount) from moneytrack.transfers tr where tr.space_id=p_space_id and tr.to_account_id=a.id and tr.transfer_date::date<=p_as_of),0)
       -coalesce((select sum(tr.from_amount) from moneytrack.transfers tr where tr.space_id=p_space_id and tr.from_account_id=a.id and tr.transfer_date::date<=p_as_of),0) as balance_original
      from moneytrack.accounts a
      left join moneytrack.transactions t on t.space_id=p_space_id and t.account_id=a.id and t.transaction_date::date<=p_as_of
      where a.space_id=p_space_id and (not exists(select 1 from chosen) or a.id in(select id from chosen))
      group by a.id,a.name,a.currency_code
    ), converted as (
      select b.*,case when b.currency_code=v_base then b.balance_original else moneytrack.finance_fx_convert_usd_bridge_v1(b.balance_original,b.currency_code,v_base,p_as_of) end as balance_base from balances b
    ), period as (
      select t.transaction_type,t.category_id,
       case when coalesce(nullif(t.currency_original,''),a.currency_code,v_base)=v_base then abs(t.amount_original)
            else moneytrack.finance_fx_convert_usd_bridge_v1(abs(t.amount_original),coalesce(nullif(t.currency_original,''),a.currency_code,v_base),v_base,t.transaction_date::date) end amount_effective
      from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
      where t.space_id=p_space_id and (not exists(select 1 from chosen) or t.account_id in(select id from chosen))
       and t.transaction_date>=p_date_from and t.transaction_date<(p_date_to+1)::date
       and (t.transaction_type<>'income' or p_income_category_ids is null or t.category_id=any(p_income_category_ids))
       and (t.transaction_type<>'expense' or p_expense_category_ids is null or t.category_id=any(p_expense_category_ids))
    ), ps as (
      select coalesce(sum(case when transaction_type='income' then amount_effective else 0 end),0) income,
             coalesce(sum(case when transaction_type='expense' then amount_effective else 0 end),0) expense,
             count(*)::bigint count from period
    )
    select p_actor_user_id,p_space_id,v_base,coalesce((select sum(c.balance_base) from converted c),0),
      coalesce((select jsonb_agg(jsonb_build_object('account_id',c.id,'name',c.name,'currency_code',c.currency_code,'balance_original',c.balance_original,'balance_base',c.balance_base) order by c.id) from converted c),'[]'::jsonb),
      coalesce((select count(*) from converted c where c.balance_base is null),0)::bigint,
      ps.income,ps.expense,ps.income-ps.expense,ps.count,p_date_from,p_date_to
    from ps;
end;$function$;

comment on function moneytrack.finance_transaction_reference_space_v1(bigint,bigint)
is 'SPC-001 reference read: global currencies plus Space-local financial categories only.';
comment on function moneytrack.api_transactions_space_read_model_v1(bigint,bigint,bigint,date,date,boolean,bigint[],bigint[],bigint[])
is 'SPC-001 UX-022 transaction read. Actor membership is asserted and every financial predicate is Space-scoped.';

commit;
