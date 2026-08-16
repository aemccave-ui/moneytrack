-- MoneyTrack — SPC-001A — Space finance hardening
--
-- Correctness layer over 020_space_finance_domain.sql. Preserves accepted
-- BE-DOM-001 FX/idempotency semantics while changing only the tenancy predicate.

begin;

create or replace function moneytrack.finance_create_transaction_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_account_id bigint,
    p_transaction_type text,
    p_amount_original numeric,
    p_currency_original text,
    p_description text default null,
    p_transaction_date timestamptz default now(),
    p_source_type text default null,
    p_source_id bigint default null,
    p_category_id bigint default null
)
returns moneytrack.transactions
language plpgsql
volatile
as $function$
declare
    v_account moneytrack.accounts%rowtype;
    v_existing moneytrack.transactions%rowtype;
    v_inserted moneytrack.transactions%rowtype;
    v_base_currency text;
    v_currency text;
    v_amount_base numeric;
    v_rate numeric;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if (p_source_type is null) <> (p_source_id is null) then
        raise exception 'SOURCE_IDENTITY_INCOMPLETE' using errcode='22023';
    end if;
    if p_transaction_type not in ('income','expense','adjustment','openingbalance') then
        raise exception 'INVALID_TRANSACTION_TYPE: %', p_transaction_type using errcode='22023';
    end if;
    if p_transaction_type = 'adjustment' then
        if p_amount_original is null or p_amount_original = 0 then
            raise exception 'INVALID_AMOUNT' using errcode='22023';
        end if;
    elsif p_amount_original is null or p_amount_original <= 0 then
        raise exception 'INVALID_AMOUNT' using errcode='22023';
    end if;
    if p_currency_original is null or btrim(p_currency_original) = '' then
        raise exception 'CURRENCY_REQUIRED' using errcode='22023';
    end if;
    if p_transaction_date is null then
        raise exception 'DATE_INVALID' using errcode='22023';
    end if;

    select a.* into v_account
    from moneytrack.accounts a
    where a.id = p_account_id
      and a.space_id = p_space_id
      and coalesce(a.is_active,true)=true;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    v_currency := upper(p_currency_original);
    if upper(v_account.currency_code) <> v_currency then
        raise exception 'ACCOUNT_CURRENCY_MISMATCH: account %, transaction %',
            upper(v_account.currency_code), v_currency using errcode='22023';
    end if;

    if p_category_id is not null and not exists (
        select 1 from moneytrack.category_catalog c
        where c.id = p_category_id
          and c.space_id = p_space_id
          and coalesce(c.is_active,true)=true
    ) then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    if p_transaction_type = 'openingbalance' then
        select t.* into v_existing from moneytrack.transactions t
        where t.space_id=p_space_id and t.account_id=p_account_id
          and t.transaction_type='openingbalance' limit 1;
        if found then return v_existing; end if;
    end if;

    if p_source_type is not null then
        select t.* into v_existing from moneytrack.transactions t
        where t.space_id=p_space_id and t.source_type=p_source_type and t.source_id=p_source_id limit 1;
        if found then
            if v_existing.account_id is distinct from p_account_id
               or v_existing.transaction_type is distinct from p_transaction_type
               or v_existing.amount_original is distinct from p_amount_original
               or upper(v_existing.currency_original) is distinct from v_currency
               or v_existing.category_id is distinct from p_category_id
            then
                raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' using errcode='23505';
            end if;
            return v_existing;
        end if;
    end if;

    select upper(s.base_currency) into v_base_currency
    from moneytrack.space_financial_settings s where s.space_id=p_space_id;
    if v_base_currency is null then
        raise exception 'SPACE_FINANCIAL_SETTINGS_MISSING' using errcode='P0001';
    end if;

    if v_currency = v_base_currency then
        v_rate := 1;
        v_amount_base := p_amount_original;
    else
        v_amount_base := moneytrack.finance_fx_convert_usd_bridge_v1(
            p_amount_original, v_currency, v_base_currency, p_transaction_date::date
        );
        if v_amount_base is null then
            raise exception 'FX_RATE_NOT_FOUND: % -> % at %',
                v_currency, v_base_currency, p_transaction_date::date using errcode='P0001';
        end if;
        v_rate := v_amount_base / p_amount_original;
    end if;

    begin
        insert into moneytrack.transactions(
            user_id, space_id, account_id, transaction_type,
            amount_original, currency_original, amount_base, currency_base, exchange_rate,
            category_id, description, transaction_date, source_type, source_id,
            created_by_user_id, updated_by_user_id
        ) values (
            p_actor_user_id, p_space_id, p_account_id, p_transaction_type,
            p_amount_original, v_currency, v_amount_base, v_base_currency, v_rate,
            p_category_id, p_description, p_transaction_date, p_source_type, p_source_id,
            p_actor_user_id, p_actor_user_id
        ) returning * into v_inserted;
    exception when unique_violation then
        if p_transaction_type = 'openingbalance' then
            select t.* into v_existing from moneytrack.transactions t
            where t.space_id=p_space_id and t.account_id=p_account_id
              and t.transaction_type='openingbalance' limit 1;
            if found then return v_existing; end if;
        end if;
        if p_source_type is null then raise; end if;
        select t.* into v_existing from moneytrack.transactions t
        where t.space_id=p_space_id and t.source_type=p_source_type and t.source_id=p_source_id limit 1;
        if not found then raise; end if;
        if v_existing.account_id is distinct from p_account_id
           or v_existing.transaction_type is distinct from p_transaction_type
           or v_existing.amount_original is distinct from p_amount_original
           or upper(v_existing.currency_original) is distinct from v_currency
           or v_existing.category_id is distinct from p_category_id
        then
            raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' using errcode='23505';
        end if;
        return v_existing;
    end;

    return v_inserted;
end;
$function$;

create or replace function moneytrack.finance_update_transaction_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_transaction_id bigint,
    p_account_id bigint,
    p_transaction_type text,
    p_amount_original numeric,
    p_currency_original text,
    p_description text,
    p_transaction_date timestamptz,
    p_category_id bigint default null
)
returns moneytrack.transactions
language plpgsql
volatile
as $function$
declare
    v_old moneytrack.transactions%rowtype;
    v_account moneytrack.accounts%rowtype;
    v_updated moneytrack.transactions%rowtype;
    v_base_currency text;
    v_currency text;
    v_amount_base numeric;
    v_rate numeric;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select t.* into v_old from moneytrack.transactions t
    where t.id=p_transaction_id and t.space_id=p_space_id for update;
    if not found then raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    if v_old.transfer_id is not null or v_old.transaction_type in ('transfer','transferexchange','exchange') then
        raise exception 'TRANSACTION_TRANSFER_EDIT_UNSUPPORTED' using errcode='22023';
    end if;
    if (coalesce(v_old.source_type,'')='photo_receipt' or exists (
        select 1 from moneytrack.receipts r
        where r.transaction_id=v_old.id and r.space_id=p_space_id
    )) and p_transaction_date is distinct from v_old.transaction_date then
        raise exception 'RECEIPT_DATETIME_IMMUTABLE' using errcode='22023';
    end if;
    if p_transaction_type not in ('income','expense','adjustment','openingbalance') then
        raise exception 'INVALID_TRANSACTION_TYPE' using errcode='22023';
    end if;
    if p_transaction_type='adjustment' then
        if p_amount_original is null or p_amount_original=0 then raise exception 'INVALID_AMOUNT' using errcode='22023'; end if;
    elsif p_amount_original is null or p_amount_original<=0 then
        raise exception 'INVALID_AMOUNT' using errcode='22023';
    end if;

    select a.* into v_account from moneytrack.accounts a
    where a.id=p_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    v_currency := upper(p_currency_original);
    if upper(v_account.currency_code) <> v_currency then
        raise exception 'ACCOUNT_CURRENCY_MISMATCH' using errcode='22023';
    end if;
    if p_category_id is not null and not exists (
        select 1 from moneytrack.category_catalog c
        where c.id=p_category_id and c.space_id=p_space_id and coalesce(c.is_active,true)=true
    ) then raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    select upper(s.base_currency) into v_base_currency
    from moneytrack.space_financial_settings s where s.space_id=p_space_id;
    if v_currency=v_base_currency then
        v_rate:=1; v_amount_base:=p_amount_original;
    else
        v_amount_base:=moneytrack.finance_fx_convert_usd_bridge_v1(
            p_amount_original,v_currency,v_base_currency,p_transaction_date::date
        );
        if v_amount_base is null then raise exception 'FX_RATE_NOT_FOUND' using errcode='P0001'; end if;
        v_rate:=v_amount_base/p_amount_original;
    end if;

    update moneytrack.transactions t
    set account_id=p_account_id,
        transaction_type=p_transaction_type,
        amount_original=p_amount_original,
        currency_original=v_currency,
        amount_base=v_amount_base,
        currency_base=v_base_currency,
        exchange_rate=v_rate,
        category_id=p_category_id,
        description=p_description,
        transaction_date=p_transaction_date,
        updated_by_user_id=p_actor_user_id
    where t.id=p_transaction_id and t.space_id=p_space_id
    returning * into v_updated;

    return v_updated;
end;
$function$;

create or replace function moneytrack.finance_create_transfer_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_from_account_id bigint,
    p_to_account_id bigint,
    p_from_amount numeric,
    p_to_amount numeric,
    p_transfer_date timestamptz default now(),
    p_transfer_type text default 'transfer',
    p_source_type text default null,
    p_source_id bigint default null
)
returns moneytrack.transfers
language plpgsql
volatile
as $function$
declare
    v_from_currency text;
    v_to_currency text;
    v_effective_to numeric;
    v_rate numeric;
    v_existing moneytrack.transfers%rowtype;
    v_inserted moneytrack.transfers%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if (p_source_type is null) <> (p_source_id is null) then raise exception 'SOURCE_IDENTITY_INCOMPLETE' using errcode='22023'; end if;
    if p_transfer_type not in ('transfer','exchange','transferexchange') then raise exception 'INVALID_TRANSFER_TYPE' using errcode='22023'; end if;
    if p_from_account_id is null or p_to_account_id is null then raise exception 'ACCOUNT_REQUIRED' using errcode='22023'; end if;
    if p_from_account_id=p_to_account_id then raise exception 'SAME_ACCOUNT_TRANSFER_FORBIDDEN' using errcode='22023'; end if;
    if p_from_amount is null or p_from_amount<=0 then raise exception 'INVALID_TRANSFER_AMOUNT' using errcode='22023'; end if;

    select upper(a.currency_code) into v_from_currency from moneytrack.accounts a
    where a.id=p_from_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true;
    if v_from_currency is null then raise exception 'FROM_ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    select upper(a.currency_code) into v_to_currency from moneytrack.accounts a
    where a.id=p_to_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true;
    if v_to_currency is null then raise exception 'TO_ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    if p_transfer_type='transfer' then
        if v_from_currency<>v_to_currency then raise exception 'TRANSFER_CURRENCY_MISMATCH' using errcode='22023'; end if;
        v_effective_to:=p_from_amount; v_rate:=1;
    else
        if v_from_currency=v_to_currency then raise exception 'EXCHANGE_REQUIRES_DIFFERENT_CURRENCIES' using errcode='22023'; end if;
        v_effective_to:=moneytrack.finance_fx_convert_usd_bridge_v1(
            p_from_amount,v_from_currency,v_to_currency,p_transfer_date::date
        );
        if v_effective_to is null or v_effective_to<=0 then raise exception 'FX_CONVERSION_UNAVAILABLE' using errcode='P0001'; end if;
        v_rate:=v_effective_to/p_from_amount;
    end if;

    if p_source_type is not null then
        select tr.* into v_existing from moneytrack.transfers tr
        where tr.space_id=p_space_id and tr.source_type=p_source_type and tr.source_id=p_source_id limit 1;
        if found then
            if v_existing.from_account_id is distinct from p_from_account_id
               or v_existing.to_account_id is distinct from p_to_account_id
               or v_existing.from_amount is distinct from p_from_amount
               or v_existing.to_amount is distinct from v_effective_to
               or v_existing.from_currency is distinct from v_from_currency
               or v_existing.to_currency is distinct from v_to_currency
               or v_existing.exchange_rate is distinct from v_rate
               or v_existing.transfer_type is distinct from p_transfer_type
               or v_existing.transfer_date is distinct from p_transfer_date
            then raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD' using errcode='23505'; end if;
            return v_existing;
        end if;
    end if;

    begin
        insert into moneytrack.transfers(
            user_id,space_id,from_account_id,to_account_id,
            from_amount,from_currency,to_amount,to_currency,exchange_rate,
            transfer_date,transfer_type,source_type,source_id,
            created_by_user_id,updated_by_user_id
        ) values (
            p_actor_user_id,p_space_id,p_from_account_id,p_to_account_id,
            p_from_amount,v_from_currency,v_effective_to,v_to_currency,v_rate,
            p_transfer_date,p_transfer_type,p_source_type,p_source_id,
            p_actor_user_id,p_actor_user_id
        ) returning * into v_inserted;
    exception when unique_violation then
        if p_source_type is null then raise; end if;
        select tr.* into v_existing from moneytrack.transfers tr
        where tr.space_id=p_space_id and tr.source_type=p_source_type and tr.source_id=p_source_id limit 1;
        if not found then raise; end if;
        return v_existing;
    end;

    return v_inserted;
end;
$function$;

create or replace function moneytrack.finance_dashboard_space_read_model_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_as_of date
)
returns table (
    actor_user_id bigint,
    space_id bigint,
    base_currency text,
    report_currency text,
    language_code text,
    date_from date,
    date_to date,
    net_worth numeric,
    income_month numeric,
    expenses_month numeric,
    result_month numeric,
    balances_by_currency jsonb,
    latest_operations jsonb
)
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    return query
    with ctx as (
        select s.base_currency,s.report_currency,
               coalesce(us.language_code,u.language_code,'en')::text as language_code,
               date_trunc('month',p_as_of)::date as date_from,
               (date_trunc('month',p_as_of)+interval '1 month - 1 day')::date as date_to
        from moneytrack.space_financial_settings s
        join moneytrack.app_users u on u.id=p_actor_user_id
        left join moneytrack.user_settings us on us.user_id=p_actor_user_id
        where s.space_id=p_space_id
    ),
    tx_movements as (
        select t.account_id,
               case when t.transaction_type in ('openingbalance','income') then t.amount_original
                    when t.transaction_type='expense' then -t.amount_original
                    when t.transaction_type='adjustment' then t.amount_original else 0 end as amount
        from moneytrack.transactions t where t.space_id=p_space_id
    ),
    transfer_movements as (
        select tr.from_account_id as account_id,-tr.from_amount as amount from moneytrack.transfers tr where tr.space_id=p_space_id
        union all
        select tr.to_account_id as account_id,tr.to_amount as amount from moneytrack.transfers tr where tr.space_id=p_space_id
    ),
    movements as (
        select * from tx_movements union all select * from transfer_movements
    ),
    raw_balances as (
        select a.id,a.currency_code,coalesce(sum(m.amount),0) as balance_original
        from moneytrack.accounts a
        left join movements m on m.account_id=a.id
        where a.space_id=p_space_id and coalesce(a.is_active,true)=true
        group by a.id,a.currency_code
    ),
    converted_balances as (
        select rb.*,
               case when rb.currency_code=ctx.base_currency then rb.balance_original
                    else moneytrack.finance_fx_convert_usd_bridge_v1(rb.balance_original,rb.currency_code,ctx.base_currency,p_as_of) end as balance_base
        from raw_balances rb cross join ctx
    ),
    month_tx as (
        select t.transaction_type,abs(coalesce(t.amount_original,0)) as amount_original,
               coalesce(nullif(t.currency_original,''),a.currency_code,ctx.base_currency)::text as source_currency,
               t.transaction_date,ctx.base_currency
        from moneytrack.transactions t
        join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
        cross join ctx
        where t.space_id=p_space_id
          and t.transaction_date>=ctx.date_from and t.transaction_date<(ctx.date_to+1)::date
    ),
    converted_month as (
        select mt.transaction_type,
               case when mt.source_currency=mt.base_currency then mt.amount_original
                    else moneytrack.finance_fx_convert_usd_bridge_v1(mt.amount_original,mt.source_currency,mt.base_currency,mt.transaction_date::date) end as amount_base
        from month_tx mt
    ),
    month_summary as (
        select coalesce(sum(case when transaction_type='income' then amount_base else 0 end),0) as income,
               coalesce(sum(case when transaction_type='expense' then amount_base else 0 end),0) as expense
        from converted_month
    ),
    by_currency as (
        select coalesce(jsonb_agg(jsonb_build_object('currency_code',x.currency_code,'balance_original',x.balance_original) order by x.currency_code),'[]'::jsonb) as payload
        from (select rb.currency_code,sum(rb.balance_original) as balance_original from raw_balances rb group by rb.currency_code) x
    ),
    latest as (
        select coalesce(jsonb_agg(to_jsonb(x) order by x.transaction_date desc,x.id desc),'[]'::jsonb) as payload
        from (
            select t.id,t.transaction_type,t.account_id,a.name as account_name,t.amount_original,t.amount_base,
                   t.currency_original,t.category_id,t.description,t.transaction_date,t.created_by_user_id
            from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
            where t.space_id=p_space_id order by t.transaction_date desc,t.id desc limit 10
        ) x
    )
    select p_actor_user_id,p_space_id,ctx.base_currency,ctx.report_currency,ctx.language_code,
           ctx.date_from,ctx.date_to,
           coalesce((select sum(cb.balance_base) from converted_balances cb),0),
           ms.income,ms.expense,ms.income-ms.expense,bc.payload,l.payload
    from ctx cross join month_summary ms cross join by_currency bc cross join latest l;
end;
$function$;

commit;
