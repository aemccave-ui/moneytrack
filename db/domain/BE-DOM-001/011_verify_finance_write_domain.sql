-- MoneyTrack — BE-DOM-001 — verification for finance_create_transaction_v1
-- Runs inside a transaction and rolls back all test writes.
-- Required psql variable: user_id

begin;

DO $verify$
declare
    v_user_id bigint := :'user_id'::bigint;
    v_account_id bigint;
    v_account_currency text;
    v_base_currency text;
    v_tx1 record;
    v_tx2 record;
    v_count bigint;
begin
    select coalesce(s.base_currency,u.default_currency,'EUR')
      into v_base_currency
      from moneytrack.app_users u
      left join moneytrack.user_settings s on s.user_id=u.id
     where u.id=v_user_id;

    if v_base_currency is null then
        raise exception 'verification user not found: %', v_user_id;
    end if;

    select a.id,a.currency_code
      into v_account_id,v_account_currency
      from moneytrack.accounts a
     where a.user_id=v_user_id
       and coalesce(a.is_active,true)=true
       and upper(a.currency_code)=upper(v_base_currency)
     order by a.id
     limit 1;

    if v_account_id is null then
        raise exception 'verification requires an active account in base currency %', v_base_currency;
    end if;

    select * into v_tx1
      from moneytrack.finance_create_transaction_v1(
        v_user_id,
        v_account_id,
        'expense',
        1.23,
        v_account_currency,
        'BE-DOM-001 verification',
        now(),
        'be_dom_001_verify',
        900000000001,
        null
      );

    if v_tx1.idempotent_replay then
        raise exception 'first create unexpectedly reported replay';
    end if;
    if v_tx1.currency_base <> upper(v_base_currency) then
        raise exception 'base currency mismatch: % <> %',v_tx1.currency_base,v_base_currency;
    end if;
    if v_tx1.amount_base <> 1.23 or v_tx1.exchange_rate <> 1 then
        raise exception 'base-currency derivation mismatch: amount_base %, rate %',v_tx1.amount_base,v_tx1.exchange_rate;
    end if;

    select * into v_tx2
      from moneytrack.finance_create_transaction_v1(
        v_user_id,
        v_account_id,
        'expense',
        1.23,
        v_account_currency,
        'BE-DOM-001 verification',
        now(),
        'be_dom_001_verify',
        900000000001,
        null
      );

    if not v_tx2.idempotent_replay or v_tx2.id <> v_tx1.id then
        raise exception 'idempotent replay failed: first %, second %, replay %',v_tx1.id,v_tx2.id,v_tx2.idempotent_replay;
    end if;

    select count(*) into v_count
      from moneytrack.transactions
     where user_id=v_user_id
       and source_type='be_dom_001_verify'
       and source_id=900000000001;

    if v_count <> 1 then
        raise exception 'idempotency produced % rows, expected 1',v_count;
    end if;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,
            v_account_id,
            'expense',
            -1,
            v_account_currency,
            null,now(),null,null,null
        );
        raise exception 'negative expense was accepted';
    exception
        when sqlstate '22023' then null;
    end;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,
            v_account_id,
            'transfer',
            1,
            v_account_currency,
            null,now(),null,null,null
        );
        raise exception 'transfer transaction_type was accepted by transaction writer';
    exception
        when sqlstate '22023' then null;
    end;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,
            -9223372036854770000,
            'expense',
            1,
            v_account_currency,
            null,now(),null,null,null
        );
        raise exception 'unknown account was accepted';
    exception
        when sqlstate 'P0002' then null;
    end;
end
$verify$;

rollback;
