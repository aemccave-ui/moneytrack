-- MoneyTrack — UX-022R3 — transfer editor domain boundary
-- Dedicated transfer mutation functions keep paired-account semantics out of
-- ordinary transaction mutation APIs.

begin;

create or replace function moneytrack.finance_get_transfer_v1(
    p_user_id bigint,
    p_transfer_id bigint
)
returns table (
    id bigint,
    user_id bigint,
    from_account_id bigint,
    from_account_name text,
    to_account_id bigint,
    to_account_name text,
    from_amount numeric,
    from_currency text,
    to_amount numeric,
    to_currency text,
    exchange_rate numeric,
    transfer_date timestamptz,
    transfer_type text
)
language plpgsql
stable
as $function$
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    return query
    select
        t.id,
        t.user_id,
        t.from_account_id,
        af.name::text,
        t.to_account_id,
        at.name::text,
        t.from_amount,
        t.from_currency::text,
        t.to_amount,
        t.to_currency::text,
        t.exchange_rate,
        t.transfer_date,
        coalesce(t.transfer_type, 'transfer')::text
    from moneytrack.transfers t
    join moneytrack.accounts af on af.id = t.from_account_id and af.user_id = t.user_id
    join moneytrack.accounts at on at.id = t.to_account_id and at.user_id = t.user_id
    where t.id = p_transfer_id
      and t.user_id = p_user_id
    limit 1;

    if not found then
        raise exception 'TRANSFER_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;
end;
$function$;

create or replace function moneytrack.finance_update_transfer_v1(
    p_user_id bigint,
    p_transfer_id bigint,
    p_from_account_id bigint,
    p_to_account_id bigint,
    p_from_amount numeric,
    p_transfer_date timestamptz,
    p_transfer_type text default null
)
returns table (
    id bigint,
    user_id bigint,
    from_account_id bigint,
    to_account_id bigint,
    from_amount numeric,
    from_currency text,
    to_amount numeric,
    to_currency text,
    exchange_rate numeric,
    transfer_date timestamptz,
    transfer_type text
)
language plpgsql
volatile
as $function$
declare
    v_existing moneytrack.transfers%rowtype;
    v_updated moneytrack.transfers%rowtype;
    v_from_currency text;
    v_to_currency text;
    v_to_amount numeric;
    v_rate numeric;
    v_type text;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    select *
      into v_existing
      from moneytrack.transfers t
     where t.id = p_transfer_id
       and t.user_id = p_user_id
     for update;

    if not found then
        raise exception 'TRANSFER_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    if p_from_account_id is null or p_to_account_id is null then
        raise exception 'ACCOUNT_REQUIRED' using errcode = '22023';
    end if;
    if p_from_account_id = p_to_account_id then
        raise exception 'SAME_ACCOUNT_TRANSFER_FORBIDDEN' using errcode = '22023';
    end if;
    if p_from_amount is null or p_from_amount <= 0 then
        raise exception 'INVALID_TRANSFER_AMOUNT' using errcode = '22023';
    end if;
    if p_transfer_date is null then
        raise exception 'DATE_REQUIRED' using errcode = '22023';
    end if;

    select upper(a.currency_code)
      into v_from_currency
      from moneytrack.accounts a
     where a.id = p_from_account_id
       and a.user_id = p_user_id
       and coalesce(a.is_active, true) = true;
    if v_from_currency is null then
        raise exception 'FROM_ACCOUNT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    select upper(a.currency_code)
      into v_to_currency
      from moneytrack.accounts a
     where a.id = p_to_account_id
       and a.user_id = p_user_id
       and coalesce(a.is_active, true) = true;
    if v_to_currency is null then
        raise exception 'TO_ACCOUNT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    v_type := coalesce(nullif(btrim(p_transfer_type), ''), nullif(btrim(v_existing.transfer_type), ''), 'transfer');
    if v_type not in ('transfer','exchange','transferexchange') then
        raise exception 'INVALID_TRANSFER_TYPE: %', v_type using errcode = '22023';
    end if;

    if v_from_currency = v_to_currency then
        -- Same-currency movements are canonical transfers.
        v_type := 'transfer';
        v_to_amount := p_from_amount;
        v_rate := 1;
    else
        -- Cross-currency movement must remain exchange-aware. Preserve explicit
        -- exchange vs transferexchange when possible, otherwise use transferexchange.
        if v_type = 'transfer' then v_type := 'transferexchange'; end if;
        v_to_amount := moneytrack.finance_fx_convert_usd_bridge_v1(
            p_from_amount,
            v_from_currency,
            v_to_currency,
            p_transfer_date::date
        );
        if v_to_amount is null or v_to_amount <= 0 then
            raise exception 'FX_CONVERSION_UNAVAILABLE: % -> % on %',
                v_from_currency, v_to_currency, p_transfer_date::date
                using errcode = 'P0001';
        end if;
        v_rate := v_to_amount / p_from_amount;
    end if;

    update moneytrack.transfers t
       set from_account_id = p_from_account_id,
           to_account_id = p_to_account_id,
           from_amount = p_from_amount,
           from_currency = v_from_currency,
           to_amount = v_to_amount,
           to_currency = v_to_currency,
           exchange_rate = v_rate,
           transfer_date = p_transfer_date,
           transfer_type = v_type
     where t.id = p_transfer_id
       and t.user_id = p_user_id
    returning * into v_updated;

    return query
    select v_updated.id, v_updated.user_id,
           v_updated.from_account_id, v_updated.to_account_id,
           v_updated.from_amount, v_updated.from_currency::text,
           v_updated.to_amount, v_updated.to_currency::text,
           v_updated.exchange_rate, v_updated.transfer_date,
           coalesce(v_updated.transfer_type, 'transfer')::text;
end;
$function$;

create or replace function moneytrack.finance_delete_transfer_v1(
    p_user_id bigint,
    p_transfer_id bigint
)
returns table (id bigint)
language plpgsql
volatile
as $function$
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    return query
    delete from moneytrack.transfers t
     where t.id = p_transfer_id
       and t.user_id = p_user_id
    returning t.id;

    if not found then
        raise exception 'TRANSFER_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;
end;
$function$;

comment on function moneytrack.finance_get_transfer_v1(bigint,bigint)
is 'UX-022R3 owned transfer detail read boundary for the MiniApp transfer editor.';

comment on function moneytrack.finance_update_transfer_v1(bigint,bigint,bigint,bigint,numeric,timestamptz,text)
is 'UX-022R3 canonical paired transfer editor. Backend owns currencies, FX result and paired-account invariants.';

comment on function moneytrack.finance_delete_transfer_v1(bigint,bigint)
is 'UX-022R3 owned transfer deletion boundary.';

commit;
