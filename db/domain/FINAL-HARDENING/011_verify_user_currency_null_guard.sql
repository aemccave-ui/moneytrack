-- MoneyTrack — FINAL-HARDENING verifier
-- Rollback-safe regression coverage for user_set_currency_v1 NULL/blank type.

begin;

DO $verify$
declare
    v_user_id bigint;
    v_currency text;
    v_base_before text;
    v_report_before text;
    v_updated_before timestamptz;
    v_status text;
    v_is_valid boolean;
    v_base_after text;
    v_report_after text;
    v_updated_after timestamptz;
begin
    select us.user_id, us.base_currency, us.report_currency, us.updated_at
      into v_user_id, v_base_before, v_report_before, v_updated_before
      from moneytrack.user_settings us
     order by case when us.user_id = 0 then 0 else 1 end, us.user_id
     limit 1;

    if v_user_id is null then
        raise exception 'FINAL-HARDENING verifier requires at least one user_settings row';
    end if;

    select c.code
      into v_currency
      from moneytrack.currencies c
     where coalesce(c.is_active, true) = true
     order by case when c.code = v_base_before then 0 else 1 end, c.code
     limit 1;

    if v_currency is null then
        raise exception 'FINAL-HARDENING verifier requires at least one active currency';
    end if;

    -- NULL type + valid currency was the three-valued-logic regression.
    select r.status, r.is_valid, r.base_currency, r.report_currency
      into v_status, v_is_valid, v_base_after, v_report_after
      from moneytrack.user_set_currency_v1(v_user_id, null, v_currency) r;

    if v_status is distinct from 'invalid_command' then
        raise exception 'NULL currency_type expected invalid_command, got %', v_status;
    end if;

    if v_is_valid is distinct from false then
        raise exception 'NULL currency_type expected is_valid=false, got %', v_is_valid;
    end if;

    if v_base_after is distinct from v_base_before
       or v_report_after is distinct from v_report_before then
        raise exception 'NULL currency_type mutated currency settings';
    end if;

    select us.updated_at
      into v_updated_after
      from moneytrack.user_settings us
     where us.user_id = v_user_id;

    if v_updated_after is distinct from v_updated_before then
        raise exception 'NULL currency_type mutated updated_at';
    end if;

    -- Blank type normalizes to NULL and must have the same semantics.
    select r.status, r.is_valid
      into v_status, v_is_valid
      from moneytrack.user_set_currency_v1(v_user_id, '   ', v_currency) r;

    if v_status is distinct from 'invalid_command'
       or v_is_valid is distinct from false then
        raise exception 'blank currency_type guard failed: status=%, is_valid=%', v_status, v_is_valid;
    end if;

    -- Preserve existing valid command behavior. Use current base currency so the
    -- value itself does not change; rollback protects updated_at as well.
    select r.status, r.is_valid
      into v_status, v_is_valid
      from moneytrack.user_set_currency_v1(v_user_id, 'base', v_base_before) r;

    if v_status is distinct from 'valid'
       or v_is_valid is distinct from true then
        raise exception 'valid base currency behavior regressed: status=%, is_valid=%', v_status, v_is_valid;
    end if;

    raise notice 'FINAL-HARDENING verifier PASS: null/blank currency_type rejected; valid base path preserved';
end;
$verify$;

rollback;
