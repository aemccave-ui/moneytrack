-- MoneyTrack — FINAL-HARDENING — user_set_currency_v1 NULL currency type guard
--
-- Fix PostgreSQL three-valued-logic edge where
--   NULL NOT IN ('base','report')
-- evaluates to NULL rather than TRUE. A request with a NULL/blank currency type
-- and a valid currency code must be classified as invalid_command and must not
-- enter the valid mutation path.

begin;

create or replace function moneytrack.user_set_currency_v1(
    p_user_id bigint,
    p_currency_type text,
    p_currency_code text
)
returns table (
    currency_type text,
    currency_code text,
    status text,
    is_valid boolean,
    base_currency text,
    report_currency text,
    available_currencies text
)
language plpgsql
volatile
as $function$
declare
    v_type text := nullif(btrim(p_currency_type), '');
    v_code text := nullif(btrim(p_currency_code), '');
    v_status text;
    v_valid boolean := false;
    v_base text;
    v_report text;
    v_available text;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if v_code is not null then
        select exists (
            select 1
            from moneytrack.currencies c
            where c.code = v_code
              and coalesce(c.is_active, true) = true
        ) into v_valid;
    end if;

    -- Explicit NULL guard is required because PostgreSQL uses three-valued
    -- boolean logic: NULL NOT IN (...) is NULL, not TRUE.
    if v_type is null or v_type not in ('base', 'report') or v_code is null then
        v_status := 'invalid_command';
    elsif not v_valid then
        v_status := 'invalid_currency';
    else
        v_status := 'valid';

        update moneytrack.user_settings us
           set base_currency = case when v_type = 'base' then v_code else us.base_currency end,
               report_currency = case when v_type = 'report' then v_code else us.report_currency end,
               updated_at = now()
         where us.user_id = p_user_id;

        if not found then
            raise exception 'USER_SETTINGS_NOT_FOUND: %', p_user_id using errcode = 'P0002';
        end if;
    end if;

    select us.base_currency, us.report_currency
      into v_base, v_report
      from moneytrack.user_settings us
     where us.user_id = p_user_id;

    select string_agg(c.code, ', ' order by c.code)
      into v_available
      from moneytrack.currencies c
     where coalesce(c.is_active, true) = true;

    return query
    select v_type, v_code, v_status, (v_status = 'valid'), v_base, v_report, v_available;
end;
$function$;

comment on function moneytrack.user_set_currency_v1(bigint,text,text)
is 'BE-DOM-003 base/report currency preference boundary. Validates active currencies, rejects null/blank currency type as invalid_command, and mutates only the selected user setting.';

commit;
