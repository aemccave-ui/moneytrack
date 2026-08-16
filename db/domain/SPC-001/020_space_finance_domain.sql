-- MoneyTrack — SPC-001A — Space-aware finance domain candidates
--
-- SOURCE ONLY. These are new actor + Space boundaries. Existing v1 compatibility
-- functions are intentionally not removed until controlled API/n8n cutover.

begin;

create unique index if not exists ux_spc001_transactions_space_source
    on moneytrack.transactions(space_id, source_type, source_id)
    where space_id is not null and source_type is not null and source_id is not null;

create unique index if not exists ux_spc001_transactions_space_opening_balance
    on moneytrack.transactions(space_id, account_id)
    where space_id is not null and transaction_type = 'openingbalance';

create unique index if not exists ux_spc001_transfers_space_source
    on moneytrack.transfers(space_id, source_type, source_id)
    where space_id is not null and source_type is not null and source_id is not null;

create or replace function moneytrack.space_financial_context_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns table (
    actor_user_id bigint,
    space_id bigint,
    base_currency text,
    report_currency text,
    language_code text
)
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    return query
    select
        p_actor_user_id,
        p_space_id,
        s.base_currency,
        s.report_currency,
        coalesce(us.language_code, u.language_code, 'en')::text
    from moneytrack.app_users u
    join moneytrack.space_financial_settings s on s.space_id = p_space_id
    left join moneytrack.user_settings us on us.user_id = p_actor_user_id
    where u.id = p_actor_user_id;
end;
$function$;

comment on function moneytrack.space_financial_context_v1(bigint,bigint)
is 'SPC-001 actor + Space context. User-global language is combined with Space-owned financial currencies only after active membership is asserted.';

-- ---------------------------------------------------------------------------
-- Accounts read model: preserves the legacy JSON shape while changing the
-- financial tenant from user_id to space_id.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.finance_accounts_space_read_model_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns table (
    actor_user_id bigint,
    space_id bigint,
    base_currency text,
    total_base numeric,
    default_account jsonb,
    accounts jsonb
)
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    return query
    with ctx as (
        select s.base_currency
        from moneytrack.space_financial_settings s
        where s.space_id = p_space_id
    ),
    account_balances as (
        select
            a.id,
            a.code,
            a.name,
            a.account_type,
            a.currency_code,
            a.parent_id,
            a.sort_order,
            coalesce(sum(t.amount_original), 0) as balance_original,
            coalesce(sum(t.amount_base), 0) as balance_base
        from moneytrack.accounts a
        left join moneytrack.transactions t
          on t.account_id = a.id
         and t.space_id = a.space_id
        where a.space_id = p_space_id
          and coalesce(a.is_active, true) = true
        group by a.id, a.code, a.name, a.account_type, a.currency_code, a.parent_id, a.sort_order
    ),
    default_account as (
        select jsonb_build_object(
            'account_id', ab.id,
            'code', ab.code,
            'name', ab.name,
            'account_name', ab.name,
            'account_type', ab.account_type,
            'currency_code', ab.currency_code,
            'balance_original', ab.balance_original,
            'balance_base', ab.balance_base
        ) as account
        from ctx
        join moneytrack.space_default_accounts d
          on d.space_id = p_space_id
         and d.currency_code = ctx.base_currency
        join account_balances ab on ab.id = d.account_id
        limit 1
    ),
    accounts_json as (
        select coalesce(jsonb_agg(
            jsonb_build_object(
                'id', ab.id,
                'code', ab.code,
                'name', ab.name,
                'account_type', ab.account_type,
                'currency_code', ab.currency_code,
                'parent_id', ab.parent_id,
                'sort_order', ab.sort_order,
                'balance_original', ab.balance_original,
                'balance_base', ab.balance_base
            )
            order by coalesce(ab.parent_id, ab.id), ab.parent_id nulls first, ab.sort_order, ab.name
        ), '[]'::jsonb) as accounts
        from account_balances ab
    )
    select
        p_actor_user_id,
        p_space_id,
        ctx.base_currency,
        coalesce((select sum(ab.balance_base) from account_balances ab), 0),
        coalesce((select da.account from default_account da), 'null'::jsonb),
        aj.accounts
    from ctx
    cross join accounts_json aj;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Dashboard read model. The calculations intentionally mirror the accepted
-- BE-DOM-001 semantics but every financial join is Space-scoped.
-- ---------------------------------------------------------------------------

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
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    return query
    with ctx as (
        select
            s.base_currency,
            s.report_currency,
            coalesce(us.language_code, u.language_code, 'en')::text as language_code,
            date_trunc('month', p_as_of)::date as date_from,
            (date_trunc('month', p_as_of) + interval '1 month - 1 day')::date as date_to
        from moneytrack.space_financial_settings s
        join moneytrack.app_users u on u.id = p_actor_user_id
        left join moneytrack.user_settings us on us.user_id = p_actor_user_id
        where s.space_id = p_space_id
    ),
    account_raw as (
        select
            a.id,
            a.currency_code,
            coalesce(sum(case
                when t.transaction_type in ('openingbalance','income','adjustment') then t.amount_original
                when t.transaction_type = 'expense' then -abs(t.amount_original)
                else 0 end), 0)
            + coalesce(sum(case when tr_in.id is not null then tr_in.to_amount else 0 end), 0)
            - coalesce(sum(case when tr_out.id is not null then tr_out.from_amount else 0 end), 0) as balance_original
        from moneytrack.accounts a
        left join moneytrack.transactions t
          on t.account_id = a.id and t.space_id = p_space_id
        left join moneytrack.transfers tr_in
          on tr_in.to_account_id = a.id and tr_in.space_id = p_space_id
        left join moneytrack.transfers tr_out
          on tr_out.from_account_id = a.id and tr_out.space_id = p_space_id
        where a.space_id = p_space_id
          and coalesce(a.is_active, true) = true
        group by a.id, a.currency_code
    ),
    account_converted as (
        select
            ar.*,
            case when ar.currency_code = ctx.base_currency then ar.balance_original
                 else moneytrack.finance_fx_convert_usd_bridge_v1(
                    ar.balance_original, ar.currency_code, ctx.base_currency, p_as_of
                 ) end as balance_base
        from account_raw ar cross join ctx
    ),
    month_tx as (
        select
            t.id,
            t.transaction_type,
            t.amount_original,
            coalesce(nullif(t.currency_original,''), a.currency_code, ctx.base_currency)::text as source_currency,
            t.transaction_date,
            t.account_id,
            t.category_id,
            t.description,
            t.created_by_user_id,
            case
                when coalesce(nullif(t.currency_original,''), a.currency_code, ctx.base_currency) = ctx.base_currency
                    then abs(coalesce(t.amount_original,0))
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    abs(coalesce(t.amount_original,0)),
                    coalesce(nullif(t.currency_original,''), a.currency_code, ctx.base_currency),
                    ctx.base_currency,
                    t.transaction_date::date
                )
            end as amount_base_effective
        from moneytrack.transactions t
        join moneytrack.accounts a on a.id = t.account_id and a.space_id = t.space_id
        cross join ctx
        where t.space_id = p_space_id
          and t.transaction_date >= ctx.date_from
          and t.transaction_date < (ctx.date_to + 1)::date
    ),
    month_summary as (
        select
            coalesce(sum(case when transaction_type = 'income' then amount_base_effective else 0 end),0) as income,
            coalesce(sum(case when transaction_type = 'expense' then amount_base_effective else 0 end),0) as expense
        from month_tx
    ),
    by_currency as (
        select coalesce(jsonb_agg(
            jsonb_build_object('currency_code', x.currency_code, 'balance_original', x.balance_original)
            order by x.currency_code
        ), '[]'::jsonb) as payload
        from (
            select ar.currency_code, sum(ar.balance_original) as balance_original
            from account_raw ar group by ar.currency_code
        ) x
    ),
    latest as (
        select coalesce(jsonb_agg(to_jsonb(x) order by x.transaction_date desc, x.id desc), '[]'::jsonb) as payload
        from (
            select
                t.id, t.transaction_type, t.account_id, a.name as account_name,
                t.amount_original, t.amount_base, t.currency_original,
                t.category_id, t.description, t.transaction_date,
                t.created_by_user_id
            from moneytrack.transactions t
            join moneytrack.accounts a on a.id = t.account_id and a.space_id = t.space_id
            where t.space_id = p_space_id
            order by t.transaction_date desc, t.id desc
            limit 10
        ) x
    )
    select
        p_actor_user_id,
        p_space_id,
        ctx.base_currency,
        ctx.report_currency,
        ctx.language_code,
        ctx.date_from,
        ctx.date_to,
        coalesce((select sum(ac.balance_base) from account_converted ac),0),
        ms.income,
        ms.expense,
        ms.income - ms.expense,
        bc.payload,
        l.payload
    from ctx
    cross join month_summary ms
    cross join by_currency bc
    cross join latest l;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Transaction list/read boundary.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.finance_transactions_space_read_model_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_date_from date,
    p_date_to date
)
returns jsonb
language plpgsql
stable
as $function$
declare
    v_result jsonb;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', t.id,
            'space_id', t.space_id,
            'transaction_type', t.transaction_type,
            'account_id', t.account_id,
            'account_name', a.name,
            'amount_original', t.amount_original,
            'amount_base', t.amount_base,
            'currency_original', t.currency_original,
            'category_id', t.category_id,
            'description', t.description,
            'transaction_date', t.transaction_date,
            'source_type', t.source_type,
            'created_by_user_id', t.created_by_user_id,
            'updated_by_user_id', t.updated_by_user_id
        )
        order by t.transaction_date desc, t.id desc
    ), '[]'::jsonb)
    into v_result
    from moneytrack.transactions t
    join moneytrack.accounts a on a.id = t.account_id and a.space_id = t.space_id
    where t.space_id = p_space_id
      and t.transaction_date >= p_date_from
      and t.transaction_date < (p_date_to + 1)::date;

    return v_result;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Canonical Space-aware transaction write.
-- created_by_user_id is immutable authorship; edits change updated_by_user_id.
-- ---------------------------------------------------------------------------

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
    v_tx moneytrack.transactions%rowtype;
    v_base_currency text;
    v_amount_base numeric;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if p_account_id is null then raise exception 'ACCOUNT_REQUIRED' using errcode='22023'; end if;
    if p_transaction_type is null then raise exception 'TYPE_REQUIRED' using errcode='22023'; end if;
    if p_amount_original is null then raise exception 'AMOUNT_REQUIRED' using errcode='22023'; end if;
    if p_transaction_date is null then raise exception 'DATE_INVALID' using errcode='22023'; end if;

    select a.* into v_account
    from moneytrack.accounts a
    where a.id = p_account_id and a.space_id = p_space_id and coalesce(a.is_active,true)=true;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    if p_category_id is not null and not exists (
        select 1 from moneytrack.category_catalog c
        where c.id = p_category_id and c.space_id = p_space_id and coalesce(c.is_active,true)=true
    ) then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    if p_source_type is not null and p_source_id is not null then
        select t.* into v_tx
        from moneytrack.transactions t
        where t.space_id = p_space_id
          and t.source_type = p_source_type
          and t.source_id = p_source_id
        limit 1;
        if found then return v_tx; end if;
    end if;

    select s.base_currency into v_base_currency
    from moneytrack.space_financial_settings s where s.space_id = p_space_id;
    if v_base_currency is null then raise exception 'SPACE_FINANCIAL_SETTINGS_MISSING' using errcode='P0001'; end if;

    v_amount_base := case
        when coalesce(nullif(p_currency_original,''), v_account.currency_code) = v_base_currency
            then abs(p_amount_original)
        else moneytrack.finance_fx_convert_usd_bridge_v1(
            abs(p_amount_original),
            coalesce(nullif(p_currency_original,''), v_account.currency_code),
            v_base_currency,
            p_transaction_date::date
        )
    end;

    insert into moneytrack.transactions(
        user_id, space_id, account_id, transaction_type,
        amount_original, currency_original, amount_base, currency_base,
        category_id, description, transaction_date,
        source_type, source_id, created_by_user_id, updated_by_user_id
    ) values (
        p_actor_user_id, p_space_id, p_account_id, p_transaction_type,
        p_amount_original, coalesce(nullif(p_currency_original,''), v_account.currency_code),
        v_amount_base, v_base_currency,
        p_category_id, p_description, p_transaction_date,
        p_source_type, p_source_id, p_actor_user_id, p_actor_user_id
    ) returning * into v_tx;

    return v_tx;
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
    v_amount_base numeric;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    select t.* into v_old from moneytrack.transactions t
    where t.id = p_transaction_id and t.space_id = p_space_id for update;
    if not found then raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    -- Preserve accepted UX-024 receipt datetime immutability without using user ownership.
    if (coalesce(v_old.source_type,'') = 'photo_receipt' or exists (
        select 1 from moneytrack.receipts r
        where r.transaction_id = v_old.id and r.space_id = p_space_id
    )) and p_transaction_date is distinct from v_old.transaction_date then
        raise exception 'RECEIPT_DATETIME_IMMUTABLE' using errcode='22023';
    end if;

    select a.* into v_account from moneytrack.accounts a
    where a.id = p_account_id and a.space_id = p_space_id and coalesce(a.is_active,true)=true;
    if not found then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    if p_category_id is not null and not exists (
        select 1 from moneytrack.category_catalog c
        where c.id = p_category_id and c.space_id = p_space_id and coalesce(c.is_active,true)=true
    ) then raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    select s.base_currency into v_base_currency from moneytrack.space_financial_settings s where s.space_id=p_space_id;
    v_amount_base := case
        when coalesce(nullif(p_currency_original,''), v_account.currency_code) = v_base_currency
            then abs(p_amount_original)
        else moneytrack.finance_fx_convert_usd_bridge_v1(
            abs(p_amount_original), coalesce(nullif(p_currency_original,''),v_account.currency_code),
            v_base_currency, p_transaction_date::date
        ) end;

    update moneytrack.transactions t
    set account_id = p_account_id,
        transaction_type = p_transaction_type,
        amount_original = p_amount_original,
        currency_original = coalesce(nullif(p_currency_original,''), v_account.currency_code),
        amount_base = v_amount_base,
        currency_base = v_base_currency,
        description = p_description,
        transaction_date = p_transaction_date,
        category_id = p_category_id,
        updated_by_user_id = p_actor_user_id
    where t.id = p_transaction_id and t.space_id = p_space_id
    returning * into v_updated;

    return v_updated;
end;
$function$;

create or replace function moneytrack.finance_delete_transaction_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_transaction_id bigint
)
returns table(status text, deleted_transaction_id bigint)
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if not exists (
        select 1 from moneytrack.transactions t
        where t.id = p_transaction_id and t.space_id = p_space_id
    ) then
        return query select 'not_found'::text, null::bigint;
        return;
    end if;

    delete from moneytrack.receipt_items ri
    using moneytrack.receipts r
    where r.id = ri.receipt_id
      and r.transaction_id = p_transaction_id
      and r.space_id = p_space_id;

    delete from moneytrack.receipts r
    where r.transaction_id = p_transaction_id and r.space_id = p_space_id;

    delete from moneytrack.transactions t
    where t.id = p_transaction_id and t.space_id = p_space_id;

    return query select 'deleted'::text, p_transaction_id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Transfer write: one Space only; both references validated in that Space.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.finance_create_transfer_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_from_account_id bigint,
    p_to_account_id bigint,
    p_from_amount numeric,
    p_to_amount numeric,
    p_transfer_date timestamptz default now(),
    p_source_type text default null,
    p_source_id bigint default null,
    p_description text default null
)
returns moneytrack.transfers
language plpgsql
volatile
as $function$
declare
    v_transfer moneytrack.transfers%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if p_from_account_id = p_to_account_id then
        raise exception 'TRANSFER_ACCOUNTS_MUST_DIFFER' using errcode='22023';
    end if;

    if not exists (select 1 from moneytrack.accounts a where a.id=p_from_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true) then
        raise exception 'FROM_ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;
    if not exists (select 1 from moneytrack.accounts a where a.id=p_to_account_id and a.space_id=p_space_id and coalesce(a.is_active,true)=true) then
        raise exception 'TO_ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    if p_source_type is not null and p_source_id is not null then
        select tr.* into v_transfer from moneytrack.transfers tr
        where tr.space_id=p_space_id and tr.source_type=p_source_type and tr.source_id=p_source_id limit 1;
        if found then return v_transfer; end if;
    end if;

    insert into moneytrack.transfers(
        user_id, space_id, from_account_id, to_account_id,
        from_amount, to_amount, transfer_date,
        source_type, source_id, description,
        created_by_user_id, updated_by_user_id
    ) values (
        p_actor_user_id, p_space_id, p_from_account_id, p_to_account_id,
        p_from_amount, p_to_amount, p_transfer_date,
        p_source_type, p_source_id, p_description,
        p_actor_user_id, p_actor_user_id
    ) returning * into v_transfer;

    return v_transfer;
end;
$function$;

comment on function moneytrack.finance_create_transfer_space_v1(bigint,bigint,bigint,bigint,numeric,numeric,timestamptz,text,bigint,text)
is 'SPC-001 Space-scoped transfer write. Active membership is sufficient; owner status is irrelevant. Cross-Space accounts fail closed.';

commit;
