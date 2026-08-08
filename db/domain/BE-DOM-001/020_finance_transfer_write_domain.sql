-- MoneyTrack — BE-DOM-001 — canonical transfer write boundary
--
-- n8n/adapters may resolve fuzzy account hints, but the backend owns all
-- financial transfer invariants and canonical persisted currencies/rates.

begin;

-- Stable source identity is optional for legacy/current adapters, but when
-- supplied it becomes the backend idempotency boundary for transfer posting.
alter table moneytrack.transfers
    add column if not exists source_type text;

alter table moneytrack.transfers
    add column if not exists source_id bigint;

create unique index if not exists ux_transfers_source_idempotency
    on moneytrack.transfers(user_id, source_type, source_id)
    where source_type is not null and source_id is not null;

create or replace function moneytrack.finance_create_transfer_v1(
    p_user_id bigint,
    p_from_account_id bigint,
    p_to_account_id bigint,
    p_from_amount numeric,
    p_to_amount numeric,
    p_transfer_date timestamptz default now(),
    p_transfer_type text default 'transfer',
    p_source_type text default null,
    p_source_id bigint default null
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
    transfer_type text,
    source_type text,
    source_id bigint,
    idempotent_replay boolean
)
language plpgsql
volatile
as $function$
declare
    v_from_currency text;
    v_to_currency text;
    v_rate numeric;
    v_existing moneytrack.transfers%rowtype;
    v_inserted moneytrack.transfers%rowtype;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if not exists (
        select 1 from moneytrack.app_users u where u.id = p_user_id
    ) then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    if (p_source_type is null) <> (p_source_id is null) then
        raise exception 'SOURCE_IDENTITY_INCOMPLETE' using errcode = '22023';
    end if;

    if p_transfer_type not in ('transfer', 'exchange', 'transferexchange') then
        raise exception 'INVALID_TRANSFER_TYPE: %', p_transfer_type using errcode = '22023';
    end if;

    if p_from_account_id is null or p_to_account_id is null then
        raise exception 'ACCOUNT_REQUIRED' using errcode = '22023';
    end if;

    if p_from_account_id = p_to_account_id then
        raise exception 'SAME_ACCOUNT_TRANSFER_FORBIDDEN' using errcode = '22023';
    end if;

    if p_from_amount is null or p_from_amount <= 0
       or p_to_amount is null or p_to_amount <= 0
    then
        raise exception 'INVALID_TRANSFER_AMOUNT' using errcode = '22023';
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

    -- Same-currency transfer is economically neutral in the current model.
    if p_transfer_type = 'transfer' then
        if v_from_currency <> v_to_currency then
            raise exception 'TRANSFER_CURRENCY_MISMATCH: % -> %',
                v_from_currency, v_to_currency using errcode = '22023';
        end if;

        if p_from_amount <> p_to_amount then
            raise exception 'TRANSFER_AMOUNT_MISMATCH: % -> %',
                p_from_amount, p_to_amount using errcode = '22023';
        end if;
    else
        -- Exchange and transferexchange represent cross-currency intent.
        if v_from_currency = v_to_currency then
            raise exception 'EXCHANGE_REQUIRES_DIFFERENT_CURRENCIES: %',
                v_from_currency using errcode = '22023';
        end if;
    end if;

    v_rate := p_to_amount / p_from_amount;

    if p_source_type is not null then
        select *
          into v_existing
          from moneytrack.transfers t
         where t.user_id = p_user_id
           and t.source_type = p_source_type
           and t.source_id = p_source_id
         limit 1;

        if found then
            if v_existing.from_account_id is distinct from p_from_account_id
               or v_existing.to_account_id is distinct from p_to_account_id
               or v_existing.from_amount is distinct from p_from_amount
               or v_existing.to_amount is distinct from p_to_amount
               or v_existing.transfer_type is distinct from p_transfer_type
               or v_existing.transfer_date is distinct from p_transfer_date
            then
                raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
                    using errcode = '23505';
            end if;

            return query
            select v_existing.id, v_existing.user_id,
                   v_existing.from_account_id, v_existing.to_account_id,
                   v_existing.from_amount, v_existing.from_currency,
                   v_existing.to_amount, v_existing.to_currency,
                   v_existing.exchange_rate, v_existing.transfer_date,
                   v_existing.transfer_type, v_existing.source_type,
                   v_existing.source_id, true;
            return;
        end if;
    end if;

    begin
        insert into moneytrack.transfers(
            user_id,
            from_account_id,
            to_account_id,
            from_amount,
            from_currency,
            to_amount,
            to_currency,
            exchange_rate,
            transfer_date,
            transfer_type,
            source_type,
            source_id
        ) values (
            p_user_id,
            p_from_account_id,
            p_to_account_id,
            p_from_amount,
            v_from_currency,
            p_to_amount,
            v_to_currency,
            v_rate,
            p_transfer_date,
            p_transfer_type,
            p_source_type,
            p_source_id
        )
        returning * into v_inserted;
    exception when unique_violation then
        if p_source_type is null then
            raise;
        end if;

        select *
          into v_existing
          from moneytrack.transfers t
         where t.user_id = p_user_id
           and t.source_type = p_source_type
           and t.source_id = p_source_id
         limit 1;

        if not found then
            raise;
        end if;

        if v_existing.from_account_id is distinct from p_from_account_id
           or v_existing.to_account_id is distinct from p_to_account_id
           or v_existing.from_amount is distinct from p_from_amount
           or v_existing.to_amount is distinct from p_to_amount
           or v_existing.transfer_type is distinct from p_transfer_type
           or v_existing.transfer_date is distinct from p_transfer_date
        then
            raise exception 'IDEMPOTENCY_KEY_REUSED_WITH_DIFFERENT_PAYLOAD'
                using errcode = '23505';
        end if;

        return query
        select v_existing.id, v_existing.user_id,
               v_existing.from_account_id, v_existing.to_account_id,
               v_existing.from_amount, v_existing.from_currency,
               v_existing.to_amount, v_existing.to_currency,
               v_existing.exchange_rate, v_existing.transfer_date,
               v_existing.transfer_type, v_existing.source_type,
               v_existing.source_id, true;
        return;
    end;

    return query
    select v_inserted.id, v_inserted.user_id,
           v_inserted.from_account_id, v_inserted.to_account_id,
           v_inserted.from_amount, v_inserted.from_currency,
           v_inserted.to_amount, v_inserted.to_currency,
           v_inserted.exchange_rate, v_inserted.transfer_date,
           v_inserted.transfer_type, v_inserted.source_type,
           v_inserted.source_id, false;
end;
$function$;

comment on function moneytrack.finance_create_transfer_v1(bigint,bigint,bigint,numeric,numeric,timestamptz,text,text,bigint)
is 'BE-DOM-001 canonical transfer writer. Derives account currencies, enforces ownership/state/type/amount/currency invariants, computes exchange rate, and supports backend source idempotency.';

commit;
