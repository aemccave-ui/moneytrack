-- MoneyTrack — BE-DOM-001 — canonical transfer writer verification
-- Usage:
--   docker exec -i moneytrack-db psql -U moneytrack -d moneytrack \
--     -v ON_ERROR_STOP=1 -v user_id=1 < 021_verify_finance_transfer_write_domain.sql
--
-- All writes are rolled back.

begin;

create temporary table be_dom_001_transfer_verify_ctx as
select :user_id::bigint as user_id;

DO $verify$
declare
    v_user_id bigint;
    v_same_from bigint;
    v_same_to bigint;
    v_same_currency text;
    v_eur_account bigint;
    v_usd_account bigint;
    v_foreign_account bigint;
    v_created record;
    v_replay record;
    v_eur_usd record;
    v_usd_eur record;
    v_expected_raw numeric;
    v_expected_to moneytrack.transfers.to_amount%type;
    v_expected_rate moneytrack.transfers.exchange_rate%type;
    v_missing_rate_date date;
begin
    select user_id into v_user_id
      from be_dom_001_transfer_verify_ctx;

    select a1.id, a2.id, upper(a1.currency_code)
      into v_same_from, v_same_to, v_same_currency
      from moneytrack.accounts a1
      join moneytrack.accounts a2
        on a2.user_id = a1.user_id
       and a2.id <> a1.id
       and upper(a2.currency_code) = upper(a1.currency_code)
       and coalesce(a2.is_active, true) = true
     where a1.user_id = v_user_id
       and coalesce(a1.is_active, true) = true
     order by a1.id, a2.id
     limit 1;

    if v_same_from is null or v_same_to is null then
        raise exception 'VERIFY_REQUIRES_TWO_ACTIVE_SAME_CURRENCY_ACCOUNTS';
    end if;

    select a.id
      into v_eur_account
      from moneytrack.accounts a
     where a.user_id = v_user_id
       and upper(a.currency_code) = 'EUR'
       and coalesce(a.is_active, true) = true
     order by a.id
     limit 1;

    select a.id
      into v_usd_account
      from moneytrack.accounts a
     where a.user_id = v_user_id
       and upper(a.currency_code) = 'USD'
       and coalesce(a.is_active, true) = true
     order by a.id
     limit 1;

    if v_eur_account is null or v_usd_account is null then
        raise exception 'VERIFY_REQUIRES_ACTIVE_EUR_AND_USD_ACCOUNTS';
    end if;

    select a.id
      into v_foreign_account
      from moneytrack.accounts a
     where a.user_id <> v_user_id
       and coalesce(a.is_active, true) = true
     order by a.id
     limit 1;

    -- Same-currency transfer: caller to_amount is non-authoritative and the
    -- persisted result must be canonical 1:1.
    select *
      into v_created
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_same_from,
          v_same_to,
          10,
          999,
          '2026-08-08 00:00:00+00'::timestamptz,
          'transfer',
          'be_dom_001_transfer_verify',
          920001
      );

    if v_created.id is null
       or v_created.from_currency <> v_same_currency
       or v_created.to_currency <> v_same_currency
       or v_created.from_amount <> 10
       or v_created.to_amount <> 10
       or v_created.exchange_rate <> 1
       or v_created.idempotent_replay
    then
        raise exception 'VERIFY_SAME_CURRENCY_CANONICAL_TRANSFER_FAILED: %', row_to_json(v_created);
    end if;

    -- EUR -> USD must exactly follow the canonical backend primitive, not the
    -- malicious/stale caller-provided to_amount=1.
    v_expected_raw := moneytrack.finance_fx_convert_usd_bridge_v1(
        10, 'EUR', 'USD', '2026-08-08'::date
    );

    if v_expected_raw is null or v_expected_raw <= 0 then
        raise exception 'VERIFY_REQUIRES_EUR_USD_FX_RATE';
    end if;

    v_expected_to := v_expected_raw;
    v_expected_rate := v_expected_raw / 10;

    select *
      into v_eur_usd
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_eur_account,
          v_usd_account,
          10,
          1,
          '2026-08-08 00:00:00+00'::timestamptz,
          'exchange',
          'be_dom_001_transfer_verify',
          920002
      );

    if v_eur_usd.from_currency <> 'EUR'
       or v_eur_usd.to_currency <> 'USD'
       or v_eur_usd.from_amount <> 10
       or v_eur_usd.to_amount is distinct from v_expected_to
       or v_eur_usd.exchange_rate is distinct from v_expected_rate
       or v_eur_usd.to_amount = 1
       or v_eur_usd.idempotent_replay
    then
        raise exception 'VERIFY_EUR_USD_BACKEND_FX_FAILED: expected_to=%, expected_rate=%, actual=%',
            v_expected_to, v_expected_rate, row_to_json(v_eur_usd);
    end if;

    -- USD -> EUR verifies the reverse direction and transferexchange semantics.
    v_expected_raw := moneytrack.finance_fx_convert_usd_bridge_v1(
        10, 'USD', 'EUR', '2026-08-08'::date
    );

    if v_expected_raw is null or v_expected_raw <= 0 then
        raise exception 'VERIFY_REQUIRES_USD_EUR_FX_RATE';
    end if;

    v_expected_to := v_expected_raw;
    v_expected_rate := v_expected_raw / 10;

    select *
      into v_usd_eur
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_usd_account,
          v_eur_account,
          10,
          1,
          '2026-08-08 00:00:00+00'::timestamptz,
          'transferexchange',
          'be_dom_001_transfer_verify',
          920003
      );

    if v_usd_eur.from_currency <> 'USD'
       or v_usd_eur.to_currency <> 'EUR'
       or v_usd_eur.from_amount <> 10
       or v_usd_eur.to_amount is distinct from v_expected_to
       or v_usd_eur.exchange_rate is distinct from v_expected_rate
       or v_usd_eur.to_amount = 1
       or v_usd_eur.idempotent_replay
    then
        raise exception 'VERIFY_USD_EUR_BACKEND_FX_FAILED: expected_to=%, expected_rate=%, actual=%',
            v_expected_to, v_expected_rate, row_to_json(v_usd_eur);
    end if;

    -- Same source identity + same canonical semantics is a replay even when
    -- caller p_to_amount changes, because p_to_amount is non-authoritative.
    select *
      into v_replay
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_eur_account,
          v_usd_account,
          10,
          999999,
          '2026-08-08 00:00:00+00'::timestamptz,
          'exchange',
          'be_dom_001_transfer_verify',
          920002
      );

    if v_replay.id <> v_eur_usd.id or not v_replay.idempotent_replay then
        raise exception 'VERIFY_TRANSFER_IDEMPOTENT_REPLAY_FAILED: %', row_to_json(v_replay);
    end if;

    -- Missing FX must fail closed. Use a date before the earliest EUR/USD rate
    -- so the canonical primitive necessarily returns NULL.
    select (min(r.rate_date) - 1)::date
      into v_missing_rate_date
      from moneytrack.exchange_rates_usd r
     where upper(r.currency_code) in ('EUR', 'USD');

    if v_missing_rate_date is null then
        v_missing_rate_date := '1900-01-01'::date;
    end if;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id,
            v_eur_account,
            v_usd_account,
            10,
            10,
            v_missing_rate_date::timestamptz,
            'exchange',
            'be_dom_001_transfer_verify',
            920004
        );
        raise exception 'VERIFY_MISSING_FX_WAS_ACCEPTED';
    exception when sqlstate 'P0001' then
        if sqlerrm not like 'FX_CONVERSION_UNAVAILABLE:%' then
            raise;
        end if;
    end;

    if exists (
        select 1
          from moneytrack.transfers t
         where t.user_id = v_user_id
           and t.source_type = 'be_dom_001_transfer_verify'
           and t.source_id = 920004
    ) then
        raise exception 'VERIFY_MISSING_FX_LEFT_PARTIAL_TRANSFER';
    end if;

    -- Invalid transfer type.
    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 10, 10, now(), 'qa_transfer', null, null
        );
        raise exception 'VERIFY_INVALID_TYPE_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    -- Same account rejection.
    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_from, 10, 10, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_SELF_TRANSFER_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    -- Invalid authoritative amount rejection.
    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 0, 999, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_ZERO_FROM_AMOUNT_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    -- Cross-currency intent cannot use the same-currency transfer type.
    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_eur_account, v_usd_account, 10, 10, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_CROSS_CURRENCY_TRANSFER_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    -- Same-currency accounts cannot be used for exchange semantics.
    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 10, 10, now(), 'exchange', null, null
        );
        raise exception 'VERIFY_SAME_CURRENCY_EXCHANGE_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    -- Account ownership remains enforced.
    if v_foreign_account is not null then
        begin
            perform * from moneytrack.finance_create_transfer_v1(
                v_user_id, v_same_from, v_foreign_account, 10, 10, now(), 'transfer', null, null
            );
            raise exception 'VERIFY_FOREIGN_ACCOUNT_WAS_ACCEPTED';
        exception when sqlstate 'P0002' then
            null;
        end;
    end if;

    -- Same idempotency key with a genuinely different semantic payload must
    -- remain a conflict.
    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id,
            v_eur_account,
            v_usd_account,
            11,
            1,
            '2026-08-08 00:00:00+00'::timestamptz,
            'exchange',
            'be_dom_001_transfer_verify',
            920002
        );
        raise exception 'VERIFY_IDEMPOTENCY_CONFLICT_WAS_ACCEPTED';
    exception when unique_violation then
        null;
    end;
end;
$verify$;

rollback;
