-- MoneyTrack — BE-DOM-005 — FX rate ingestion domain boundary
--
-- Moves the final direct business-table mutation out of n8n while preserving
-- the existing single-row USD-base rate upsert semantics.

begin;

create or replace function moneytrack.fx_upsert_usd_rate_v1(
    p_rate_date date,
    p_currency_code character varying,
    p_usd_rate numeric,
    p_source text
)
returns table (
    rate_date date,
    currency_code character varying,
    usd_rate numeric,
    source text,
    created_at timestamptz
)
language sql
volatile
as $function$
    insert into moneytrack.exchange_rates_usd (
        rate_date,
        currency_code,
        usd_rate,
        source
    )
    values (
        p_rate_date,
        p_currency_code,
        p_usd_rate,
        p_source
    )
    on conflict on constraint exchange_rates_usd_pkey
    do update set
        usd_rate = excluded.usd_rate,
        source = excluded.source,
        created_at = now()
    returning
        exchange_rates_usd.rate_date,
        exchange_rates_usd.currency_code,
        exchange_rates_usd.usd_rate,
        exchange_rates_usd.source,
        exchange_rates_usd.created_at;
$function$;

comment on function moneytrack.fx_upsert_usd_rate_v1(date, character varying, numeric, text)
is 'BE-DOM-005 canonical backend boundary for single-row USD-base FX rate ingestion/upsert.';

commit;
