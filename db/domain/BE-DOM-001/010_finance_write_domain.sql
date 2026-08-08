-- MoneyTrack — BE-DOM-001 — canonical finance write boundary
--
-- This migration introduces backend-enforced transaction creation semantics.
-- n8n/adapters pass intent only; derived base-currency values are computed here.

begin;

-- Stable source identity is the backend idempotency boundary.
-- Existing legacy rows all have source_id NULL, so this does not rewrite or reject them.
create unique index if not exists ux_transactions_source_idempotency
    on moneytrack.transactions(user_id, source_type, source_id)
    where source_type is not null and source_id is not null;

-- Legacy opening-balance behavior permits at most one opening balance per account.
create unique index if not exists ux_transactions_one_opening_balance_per_account
    on moneytrack.transactions(user_id, account_id)
    where transaction_type = 'openingbalance';

create or replace function moneytrack.finance_create_transaction_v1(
    p_user_id bigint,
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
    v_base_currency text;
    v_account_currency text;
    v_amount_base numeric;
    v_rate numeric;
    v_existing moneytrack.transactions%rowtype;
    v_inserted moneytrack.transactions%rowtype;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if (p_source_type is null) <> (p_source_id is null) then
        raise exception 'SOURCE_IDENTITY_INCOMPLETE' using errcode = '22023';
    end if;

    select upper(coalesce(s.base_currency, u.default_currency, 'EUR'))
      into v_base_currency
      from moneytrack.app_users u
      left join moneytrack.user_settings s on s.user_id = u.id
     where u.id = p_user_id;

    if v_base_currency is null then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    if p_transaction_type not in ('income','expense','adjustment','openingbalance') then
        raise exception 'INVALID_TRANSACTION_TYPE: %', p_transaction_type using errcode = '22023';
    end if;

    if p_transaction_type = 'adjustment' then
        if p_amount_original is null or p_amount_original = 0 then
            raise exception 'INVALID_AMOUNT' using errcode = '22023';
        end if;
    else
        if p_amount_original is null or p_amount_original <= 0 then
            raise exception 'INVALID_AMOUNT' using errcode = '22023';
        end if;
    end if;

    if p_currency_original is null or btrim(p_currency_original) = '' then
        raise exception 'CURRENCY_REQUIRED' using errcode = '22023';
    end if;

    select upper(a.currency_code)
      into v_account_currency
      from moneytrack.accounts a
     where a.id = p_account_id
       and a.user_id = p_user_id
       and coalesce(a.is_active, true) = true;

    if v_account_currency is null then
        raise exception 'ACCOUNT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    if v_account_currency <> upper(p_currency_original) then
        raise exception 'ACCOUNT_CURRENCY_MISMATCH: account %, transaction %',
            v_account_currency, upper(p_currency_original) using errcode = '22023';
    end if;

    if p_category_id is not null and not exists (
        select 1
          from moneytrack.category_catalog c
         where c.id = p_category_id
           and c.user_id = p_user_id
    ) then
        raise exception 'CATEGORY_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    -- Opening balance uniqueness is a domain invariant, not an adapter concern.
    -- A repeated request for an account that already has an opening balance returns
    -- the existing posting as a replay, preserving the legacy "already_exists" UX.
    if p_transaction_type = 'openingbalance' then
        select *
          into v_existing
          from moneytrack.transactions t
         where t.user_id = p_user_id
           and t.account_id = p_account_id
           and t.transaction_type = 'openingbalance'
         limit 1;

        if found then
            return query
            select v_existing.id, v_existing.user_id, v_existing.account_id,
                   v_existing.transaction_type, v_existing.amount_original,
                   v_existing.currency_original, v_existing.amount_base,
                   v_existing.currency_base, v_existing.exchange_rate,
                   v_existing.category_id, v_existing.description,
                   v_existing.transaction_date, v_existing.source_type,
                   v_existing.source_id, true;
            return;
        end if;
    end if;

    if p_source_type is not null then
        select *
          into v_existing
          from moneytrack.transactions t
         where t.user_id = p_user_id
           and t.source_type = p_source_type
           and t.source_id = p_source_id
         limit 1;

        if found then
            if v_existing.account_id is distinct from p_account_id
               or v_existing.transaction_type is distinct from p_transaction_type
               or v_existing.amount_original is distinct from p_amount_original
               or upper(v_existing.currency_original) is distinct from upper(p_currency_original)
               or v_existing.category_id is distinct from p_category_id
            then
                raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
                    using errcode = '23505';
            end if;

            return query
            select v_existing.id, v_existing.user_id, v_existing.account_id,
                   v_existing.transaction_type, v_existing.amount_original,
                   v_existing.currency_original, v_existing.amount_base,
                   v_existing.currency_base, v_existing.exchange_rate,
                   v_existing.category_id, v_existing.description,
                   v_existing.transaction_date, v_existing.source_type,
                   v_existing.source_id, true;
            return;
        end if;
    end if;

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
            raise exception 'FX_RATE_NOT_FOUND: % -> % at %',
                upper(p_currency_original), v_base_currency, p_transaction_date::date
                using errcode = 'P0001';
        end if;

        v_rate := v_amount_base / p_amount_original;
    end if;

    begin
        insert into moneytrack.transactions(
            user_id, account_id, transaction_type,
            amount_original, currency_original,
            amount_base, currency_base, exchange_rate,
            category_id, description, transaction_date,
            source_type, source_id
        ) values (
            p_user_id, p_account_id, p_transaction_type,
            p_amount_original, upper(p_currency_original),
            v_amount_base, v_base_currency, v_rate,
            p_category_id, p_description, p_transaction_date,
            p_source_type, p_source_id
        )
        returning * into v_inserted;
    exception when unique_violation then
        -- Race-safe opening-balance replay: concurrent requests may both pass the
        -- pre-check, but only one may insert because of the partial unique index.
        if p_transaction_type = 'openingbalance' then
            select *
              into v_existing
              from moneytrack.transactions t
             where t.user_id = p_user_id
               and t.account_id = p_account_id
               and t.transaction_type = 'openingbalance'
             limit 1;

            if found then
                return query
                select v_existing.id, v_existing.user_id, v_existing.account_id,
                       v_existing.transaction_type, v_existing.amount_original,
                       v_existing.currency_original, v_existing.amount_base,
                       v_existing.currency_base, v_existing.exchange_rate,
                       v_existing.category_id, v_existing.description,
                       v_existing.transaction_date, v_existing.source_type,
                       v_existing.source_id, true;
                return;
            end if;
        end if;

        if p_source_type is null then
            raise;
        end if;

        select *
          into v_existing
          from moneytrack.transactions t
         where t.user_id = p_user_id
           and t.source_type = p_source_type
           and t.source_id = p_source_id
         limit 1;

        if not found then
            raise;
        end if;

        if v_existing.account_id is distinct from p_account_id
           or v_existing.transaction_type is distinct from p_transaction_type
           or v_existing.amount_original is distinct from p_amount_original
           or upper(v_existing.currency_original) is distinct from upper(p_currency_original)
           or v_existing.category_id is distinct from p_category_id
        then
            raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
                using errcode = '23505';
        end if;

        return query
        select v_existing.id, v_existing.user_id, v_existing.account_id,
               v_existing.transaction_type, v_existing.amount_original,
               v_existing.currency_original, v_existing.amount_base,
               v_existing.currency_base, v_existing.exchange_rate,
               v_existing.category_id, v_existing.description,
               v_existing.transaction_date, v_existing.source_type,
               v_existing.source_id, true;
        return;
    end;

    return query
    select v_inserted.id, v_inserted.user_id, v_inserted.account_id,
           v_inserted.transaction_type, v_inserted.amount_original,
           v_inserted.currency_original, v_inserted.amount_base,
           v_inserted.currency_base, v_inserted.exchange_rate,
           v_inserted.category_id, v_inserted.description,
           v_inserted.transaction_date, v_inserted.source_type,
           v_inserted.source_id, false;
end;
$function$;

comment on function moneytrack.finance_create_transaction_v1(bigint,bigint,text,numeric,text,text,timestamptz,text,bigint,bigint)
is 'BE-DOM-001 canonical transaction writer. Enforces account/category ownership, transaction/amount/currency invariants, backend base valuation, opening-balance uniqueness/replay and source idempotency.';

commit;
