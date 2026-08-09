-- MoneyTrack — BE-DOM-005 — rollback-safe FX rate ingestion verifier
--
-- Uses a synthetic future date/currency key and rolls back all mutations.

begin;

DO $verify$
declare
    v_date date := date '2099-12-31';
    v_code character varying := 'ZZZ';
    v_count integer;
    v_rate numeric;
    v_source text;
begin
    if exists (
        select 1
        from moneytrack.exchange_rates_usd r
        where r.rate_date = v_date
          and r.currency_code = v_code
    ) then
        raise exception 'BE-DOM-005 verifier fixture already exists for %/%', v_date, v_code;
    end if;

    perform 1
    from moneytrack.fx_upsert_usd_rate_v1(
        v_date,
        v_code,
        1.23456789,
        'be-dom-005-verifier-insert'
    );

    select count(*)::integer, max(r.usd_rate), max(r.source)
      into v_count, v_rate, v_source
      from moneytrack.exchange_rates_usd r
     where r.rate_date = v_date
       and r.currency_code = v_code;

    if v_count <> 1 then
        raise exception 'initial FX upsert created % rows instead of 1', v_count;
    end if;

    if v_rate is distinct from 1.23456789::numeric
       or v_source is distinct from 'be-dom-005-verifier-insert' then
        raise exception 'initial FX upsert values mismatch: rate %, source %', v_rate, v_source;
    end if;

    perform 1
    from moneytrack.fx_upsert_usd_rate_v1(
        v_date,
        v_code,
        9.87654321,
        'be-dom-005-verifier-update'
    );

    select count(*)::integer, max(r.usd_rate), max(r.source)
      into v_count, v_rate, v_source
      from moneytrack.exchange_rates_usd r
     where r.rate_date = v_date
       and r.currency_code = v_code;

    if v_count <> 1 then
        raise exception 'conflict FX upsert duplicated key: % rows', v_count;
    end if;

    if v_rate is distinct from 9.87654321::numeric
       or v_source is distinct from 'be-dom-005-verifier-update' then
        raise exception 'conflict FX upsert did not update values: rate %, source %', v_rate, v_source;
    end if;

    raise notice 'BE-DOM-005 verifier PASS: insert/conflict-update/single-key semantics';
end
$verify$;

rollback;
