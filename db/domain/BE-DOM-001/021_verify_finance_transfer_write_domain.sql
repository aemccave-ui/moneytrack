-- MoneyTrack — BE-DOM-001 — canonical transfer writer verification
-- Usage:
--   psql -v ON_ERROR_STOP=1 -v user_id=1 < 021_verify_finance_transfer_write_domain.sql
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
    v_cross_from bigint;
    v_cross_to bigint;
    v_cross_from_currency text;
    v_cross_to_currency text;
    v_foreign_account bigint;
    v_created record;
    v_replay record;
    v_exchange record;
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

    select a1.id, a2.id, upper(a1.currency_code), upper(a2.currency_code)
      into v_cross_from, v_cross_to, v_cross_from_currency, v_cross_to_currency
      from moneytrack.accounts a1
      join moneytrack.accounts a2
        on a2.user_id = a1.user_id
       and a2.id <> a1.id
       and upper(a2.currency_code) <> upper(a1.currency_code)
       and coalesce(a2.is_active, true) = true
     where a1.user_id = v_user_id
       and coalesce(a1.is_active, true) = true
     order by a1.id, a2.id
     limit 1;

    if v_cross_from is null or v_cross_to is null then
        raise exception 'VERIFY_REQUIRES_TWO_ACTIVE_CROSS_CURRENCY_ACCOUNTS';
    end if;

    select a.id
      into v_foreign_account
      from moneytrack.accounts a
     where a.user_id <> v_user_id
       and coalesce(a.is_active, true) = true
     order by a.id
     limit 1;

    select *
      into v_created
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_same_from,
          v_same_to,
          10,
          10,
          '2026-08-08 00:00:00+00'::timestamptz,
          'transfer',
          'be_dom_001_transfer_verify',
          910001
      );

    if v_created.id is null
       or v_created.from_currency <> v_same_currency
       or v_created.to_currency <> v_same_currency
       or v_created.exchange_rate <> 1
       or v_created.idempotent_replay
    then
        raise exception 'VERIFY_SAME_CURRENCY_TRANSFER_FAILED: %', row_to_json(v_created);
    end if;

    select *
      into v_replay
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_same_from,
          v_same_to,
          10,
          10,
          '2026-08-08 00:00:00+00'::timestamptz,
          'transfer',
          'be_dom_001_transfer_verify',
          910001
      );

    if v_replay.id <> v_created.id or not v_replay.idempotent_replay then
        raise exception 'VERIFY_TRANSFER_IDEMPOTENT_REPLAY_FAILED';
    end if;

    select *
      into v_exchange
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_cross_from,
          v_cross_to,
          100,
          125,
          '2026-08-08 00:00:00+00'::timestamptz,
          'exchange',
          'be_dom_001_transfer_verify',
          910002
      );

    if v_exchange.from_currency <> v_cross_from_currency
       or v_exchange.to_currency <> v_cross_to_currency
       or v_exchange.exchange_rate <> 1.25
       or v_exchange.idempotent_replay
    then
        raise exception 'VERIFY_CROSS_CURRENCY_EXCHANGE_FAILED: %', row_to_json(v_exchange);
    end if;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 10, 10, now(), 'qa_transfer', null, null
        );
        raise exception 'VERIFY_INVALID_TYPE_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_from, 10, 10, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_SELF_TRANSFER_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 0, 0, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_ZERO_AMOUNT_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 10, 11, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_SAME_CURRENCY_AMOUNT_MISMATCH_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_cross_from, v_cross_to, 10, 10, now(), 'transfer', null, null
        );
        raise exception 'VERIFY_CROSS_CURRENCY_TRANSFER_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id, v_same_from, v_same_to, 10, 10, now(), 'exchange', null, null
        );
        raise exception 'VERIFY_SAME_CURRENCY_EXCHANGE_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        null;
    end;

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

    begin
        perform * from moneytrack.finance_create_transfer_v1(
            v_user_id,
            v_same_from,
            v_same_to,
            11,
            11,
            '2026-08-08 00:00:00+00'::timestamptz,
            'transfer',
            'be_dom_001_transfer_verify',
            910001
        );
        raise exception 'VERIFY_IDEMPOTENCY_CONFLICT_WAS_ACCEPTED';
    exception when unique_violation then
        null;
    end;
end;
$verify$;

rollback;
