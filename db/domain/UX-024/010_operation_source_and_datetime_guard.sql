-- MoneyTrack — UX-024 — canonical operation source + receipt datetime immutability
-- Source-only until controlled preview apply.

begin;

create or replace function moneytrack.operation_source_kind_v1(
    p_user_id bigint,
    p_transaction_id bigint
)
returns text
language sql
stable
as $function$
    select case
        when exists (
            select 1
            from moneytrack.receipts r
            where r.user_id = p_user_id
              and r.transaction_id = p_transaction_id
        ) then 'photo_receipt'::text
        when lower(coalesce(t.source_type, '')) in ('photo_receipt', 'photo') then 'photo_receipt'::text
        when lower(coalesce(t.source_type, '')) = 'voice' then 'voice'::text
        when lower(coalesce(t.source_type, '')) = 'text' then 'text'::text
        when lower(coalesce(t.source_type, '')) in ('miniapp', 'manual') then 'manual'::text
        else null::text
    end
    from moneytrack.transactions t
    where t.id = p_transaction_id
      and t.user_id = p_user_id;
$function$;

comment on function moneytrack.operation_source_kind_v1(bigint,bigint)
is 'UX-024 persisted operation source resolver. Uses receipt relation and persisted source_type only; never operation-content heuristics.';

create or replace function moneytrack.finance_create_sourced_transaction_v1(
    p_user_id bigint,
    p_account_id bigint,
    p_transaction_type text,
    p_amount_original numeric,
    p_currency_original text,
    p_description text default null,
    p_transaction_date timestamptz default now(),
    p_operation_source text default null,
    p_category_id bigint default null
)
returns table (
    id bigint,
    user_id bigint,
    account_id bigint,
    transaction_type text,
    amount_original numeric,
    currency_original text,
    amount_base numeric,
    currency_base text,
    exchange_rate numeric,
    category_id bigint,
    description text,
    transaction_date timestamptz,
    source_type text,
    source_id bigint,
    idempotent_replay boolean
)
language plpgsql
volatile
as $function$
declare
    v_created record;
    v_source text := lower(nullif(btrim(p_operation_source), ''));
begin
    if v_source not in ('text','voice','photo_receipt') then
        raise exception 'OPERATION_SOURCE_INVALID' using errcode = '22023';
    end if;

    select * into v_created
    from moneytrack.finance_create_transaction_v1(
        p_user_id,
        p_account_id,
        p_transaction_type,
        p_amount_original,
        p_currency_original,
        p_description,
        p_transaction_date,
        null,
        null,
        p_category_id
    );

    if not coalesce(v_created.idempotent_replay, false) then
        update moneytrack.transactions t
           set source_type = v_source
         where t.id = v_created.id
           and t.user_id = p_user_id
           and t.source_type is null;
    end if;

    return query
    select
        v_created.id::bigint,
        v_created.user_id::bigint,
        v_created.account_id::bigint,
        v_created.transaction_type::text,
        v_created.amount_original::numeric,
        v_created.currency_original::text,
        v_created.amount_base::numeric,
        v_created.currency_base::text,
        v_created.exchange_rate::numeric,
        v_created.category_id::bigint,
        v_created.description::text,
        v_created.transaction_date::timestamptz,
        coalesce(v_source, v_created.source_type)::text,
        v_created.source_id::bigint,
        v_created.idempotent_replay::boolean;
end;
$function$;

comment on function moneytrack.finance_create_sourced_transaction_v1(bigint,bigint,text,numeric,text,text,timestamptz,text,bigint)
is 'UX-024 transaction create wrapper for non-manual ingress. Persists text/voice/photo_receipt source without inventing an idempotency key; core finance_create_transaction_v1 remains authoritative for financial invariants.';

create or replace function moneytrack.finance_update_transaction_v1(
    p_user_id bigint,
    p_transaction_id bigint,
    p_account_id bigint,
    p_transaction_type text,
    p_amount_original numeric,
    p_currency_original text,
    p_description text,
    p_transaction_date timestamptz,
    p_category_id bigint default null
)
returns table (
    id bigint,
    user_id bigint,
    account_id bigint,
    transaction_type text,
    amount_original numeric,
    currency_original text,
    amount_base numeric,
    currency_base text,
    exchange_rate numeric,
    category_id bigint,
    description text,
    transaction_date timestamptz,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_tx moneytrack.transactions%rowtype;
    v_account moneytrack.accounts%rowtype;
    v_updated moneytrack.transactions%rowtype;
    v_base_currency text;
    v_amount_base numeric;
    v_rate numeric;
begin
    if p_user_id is null then raise exception 'USER_REQUIRED' using errcode = '22023'; end if;
    if p_transaction_id is null then raise exception 'TRANSACTION_REQUIRED' using errcode = '22023'; end if;
    if p_account_id is null then raise exception 'ACCOUNT_REQUIRED' using errcode = '22023'; end if;
    if p_transaction_date is null then raise exception 'DATE_INVALID' using errcode = '22023'; end if;

    select t.* into v_tx
    from moneytrack.transactions t
    where t.id = p_transaction_id
      and t.user_id = p_user_id
    for update;

    if not found then raise exception 'TRANSACTION_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002'; end if;

    if v_tx.transfer_id is not null
       or v_tx.transaction_type in ('transfer','transferexchange','exchange')
    then
        raise exception 'TRANSACTION_TRANSFER_EDIT_UNSUPPORTED' using errcode = '22023';
    end if;

    if moneytrack.operation_source_kind_v1(p_user_id, p_transaction_id) = 'photo_receipt'
       and p_transaction_date is distinct from v_tx.transaction_date
    then
        raise exception 'RECEIPT_DATETIME_IMMUTABLE' using errcode = '22023';
    end if;

    if p_transaction_type not in ('income','expense','adjustment','openingbalance') then
        raise exception 'INVALID_TRANSACTION_TYPE' using errcode = '22023';
    end if;

    if p_transaction_type = 'adjustment' then
        if p_amount_original is null or p_amount_original = 0 then raise exception 'INVALID_AMOUNT' using errcode = '22023'; end if;
    elsif p_amount_original is null or p_amount_original <= 0 then
        raise exception 'INVALID_AMOUNT' using errcode = '22023';
    end if;

    if p_currency_original is null or btrim(p_currency_original) = '' then
        raise exception 'CURRENCY_REQUIRED' using errcode = '22023';
    end if;

    select a.* into v_account
    from moneytrack.accounts a
    where a.id = p_account_id
      and a.user_id = p_user_id
      and coalesce(a.is_active, true) = true;

    if not found then raise exception 'ACCOUNT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002'; end if;

    if exists (
        select 1 from moneytrack.accounts child
        where child.parent_id = v_account.id
          and child.user_id = p_user_id
          and coalesce(child.is_active, true) = true
    ) then
        raise exception 'ACCOUNT_GROUP_NOT_POSTABLE' using errcode = '22023';
    end if;

    if upper(v_account.currency_code) <> upper(p_currency_original) then
        raise exception 'ACCOUNT_CURRENCY_MISMATCH: account %, transaction %',
            upper(v_account.currency_code), upper(p_currency_original)
            using errcode = '22023';
    end if;

    if p_category_id is not null and not exists (
        select 1 from moneytrack.category_catalog c
        where c.id = p_category_id and c.user_id = p_user_id
    ) then
        raise exception 'CATEGORY_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    if p_transaction_type = 'openingbalance' and exists (
        select 1 from moneytrack.transactions other
        where other.user_id = p_user_id
          and other.account_id = p_account_id
          and other.transaction_type = 'openingbalance'
          and other.id <> p_transaction_id
    ) then
        raise exception 'OPENING_BALANCE_ALREADY_EXISTS' using errcode = '23505';
    end if;

    select upper(coalesce(s.base_currency, u.default_currency, 'EUR'))
      into v_base_currency
      from moneytrack.app_users u
      left join moneytrack.user_settings s on s.user_id = u.id
     where u.id = p_user_id;

    if v_base_currency is null then raise exception 'USER_NOT_FOUND' using errcode = 'P0002'; end if;

    if upper(p_currency_original) = v_base_currency then
        v_rate := 1;
        v_amount_base := p_amount_original;
    else
        v_amount_base := moneytrack.finance_fx_convert_usd_bridge_v1(
            p_amount_original,
            upper(p_currency_original),
            v_base_currency,
            p_transaction_date::date
        );
        if v_amount_base is null then
            raise exception 'FX_RATE_NOT_FOUND: % -> % at %', upper(p_currency_original), v_base_currency, p_transaction_date::date using errcode = 'P0001';
        end if;
        v_rate := v_amount_base / p_amount_original;
    end if;

    update moneytrack.transactions t
       set account_id = p_account_id,
           transaction_type = p_transaction_type,
           amount_original = p_amount_original,
           currency_original = upper(p_currency_original),
           amount_base = v_amount_base,
           currency_base = v_base_currency,
           exchange_rate = v_rate,
           category_id = p_category_id,
           description = nullif(btrim(p_description), ''),
           transaction_date = p_transaction_date
     where t.id = p_transaction_id
       and t.user_id = p_user_id
     returning t.* into v_updated;

    return query
    select v_updated.id, v_updated.user_id, v_updated.account_id,
           v_updated.transaction_type, v_updated.amount_original,
           v_updated.currency_original, v_updated.amount_base,
           v_updated.currency_base, v_updated.exchange_rate,
           v_updated.category_id, v_updated.description,
           v_updated.transaction_date, 'updated'::text;
end;
$function$;

comment on function moneytrack.finance_update_transaction_v1(bigint,bigint,bigint,text,numeric,text,text,timestamptz,bigint)
is 'UX-024 canonical full edit for ordinary transactions. Preserves UX-022 invariants and rejects datetime mutation for persisted photo-receipt operations.';

commit;
