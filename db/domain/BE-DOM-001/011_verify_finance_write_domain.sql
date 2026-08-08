-- MoneyTrack — BE-DOM-001 — verification for finance_create_transaction_v1
-- Runs inside a transaction and rolls back all test writes.
-- Required psql variable: user_id

begin;

create temp table be_dom_001_verify_params(user_id bigint) on commit drop;
insert into be_dom_001_verify_params(user_id) values (:'user_id'::bigint);

DO $verify$
declare
    v_user_id bigint;
    v_account_id bigint;
    v_account_currency text;
    v_opening_account_id bigint;
    v_opening_currency text;
    v_base_currency text;
    v_tx1 record;
    v_tx2 record;
    v_ob1 record;
    v_ob2 record;
    v_count bigint;
begin
    select user_id into v_user_id from be_dom_001_verify_params limit 1;

    select upper(coalesce(s.base_currency,u.default_currency,'EUR'))
      into v_base_currency
      from moneytrack.app_users u
      left join moneytrack.user_settings s on s.user_id=u.id
     where u.id=v_user_id;

    if v_base_currency is null then
        raise exception 'verification user not found: %', v_user_id;
    end if;

    select a.id,upper(a.currency_code)
      into v_account_id,v_account_currency
      from moneytrack.accounts a
     where a.user_id=v_user_id
       and coalesce(a.is_active,true)=true
       and upper(a.currency_code)=v_base_currency
     order by a.id
     limit 1;

    if v_account_id is null then
        raise exception 'verification requires an active account in base currency %', v_base_currency;
    end if;

    select * into v_tx1
      from moneytrack.finance_create_transaction_v1(
        v_user_id,v_account_id,'expense',1.23,v_account_currency,
        'BE-DOM-001 verification',now(),'be_dom_001_verify',900000000001,null
      );

    if v_tx1.idempotent_replay then
        raise exception 'first create unexpectedly reported replay';
    end if;
    if v_tx1.currency_base <> v_base_currency then
        raise exception 'base currency mismatch: % <> %',v_tx1.currency_base,v_base_currency;
    end if;
    if v_tx1.amount_base <> 1.23 or v_tx1.exchange_rate <> 1 then
        raise exception 'base-currency derivation mismatch: amount_base %, rate %',v_tx1.amount_base,v_tx1.exchange_rate;
    end if;

    select * into v_tx2
      from moneytrack.finance_create_transaction_v1(
        v_user_id,v_account_id,'expense',1.23,v_account_currency,
        'BE-DOM-001 verification',now(),'be_dom_001_verify',900000000001,null
      );

    if not v_tx2.idempotent_replay or v_tx2.id <> v_tx1.id then
        raise exception 'idempotent replay failed: first %, second %, replay %',v_tx1.id,v_tx2.id,v_tx2.idempotent_replay;
    end if;

    select count(*) into v_count
      from moneytrack.transactions
     where user_id=v_user_id and source_type='be_dom_001_verify' and source_id=900000000001;
    if v_count <> 1 then
        raise exception 'idempotency produced % rows, expected 1',v_count;
    end if;

    -- Pick an account without an existing opening balance so the first call creates
    -- a posting and the second call proves backend-level already-exists replay.
    select a.id,upper(a.currency_code)
      into v_opening_account_id,v_opening_currency
      from moneytrack.accounts a
     where a.user_id=v_user_id
       and coalesce(a.is_active,true)=true
       and not exists (
           select 1 from moneytrack.transactions t
            where t.user_id=v_user_id
              and t.account_id=a.id
              and t.transaction_type='openingbalance'
       )
     order by case when upper(a.currency_code)=v_base_currency then 0 else 1 end,a.id
     limit 1;

    if v_opening_account_id is null then
        raise exception 'verification requires an active account without opening balance';
    end if;

    select * into v_ob1
      from moneytrack.finance_create_transaction_v1(
        v_user_id,v_opening_account_id,'openingbalance',10,v_opening_currency,
        'BE-DOM-001 opening balance verification',now(),null,null,null
      );
    if v_ob1.idempotent_replay then
        raise exception 'first opening balance unexpectedly reported replay';
    end if;

    select * into v_ob2
      from moneytrack.finance_create_transaction_v1(
        v_user_id,v_opening_account_id,'openingbalance',99,v_opening_currency,
        'different retry payload',now(),null,null,null
      );
    if not v_ob2.idempotent_replay or v_ob2.id <> v_ob1.id then
        raise exception 'opening balance replay failed: first %, second %, replay %',v_ob1.id,v_ob2.id,v_ob2.idempotent_replay;
    end if;

    select count(*) into v_count
      from moneytrack.transactions
     where user_id=v_user_id
       and account_id=v_opening_account_id
       and transaction_type='openingbalance';
    if v_count <> 1 then
        raise exception 'opening balance uniqueness produced % rows, expected 1',v_count;
    end if;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,v_account_id,'expense',-1,v_account_currency,null,now(),null,null,null
        );
        raise exception 'negative expense was accepted';
    exception when sqlstate '22023' then null;
    end;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,v_account_id,'transfer',1,v_account_currency,null,now(),null,null,null
        );
        raise exception 'transfer transaction_type was accepted by transaction writer';
    exception when sqlstate '22023' then null;
    end;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,-9223372036854770000,'expense',1,v_account_currency,null,now(),null,null,null
        );
        raise exception 'unknown account was accepted';
    exception when sqlstate 'P0002' then null;
    end;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,v_account_id,'expense',1,v_account_currency,null,now(),'incomplete_source',null,null
        );
        raise exception 'incomplete source identity was accepted';
    exception when sqlstate '22023' then null;
    end;

    begin
        perform * from moneytrack.finance_create_transaction_v1(
            v_user_id,v_account_id,'expense',9.99,v_account_currency,
            'different payload',now(),'be_dom_001_verify',900000000001,null
        );
        raise exception 'reused idempotency key with different payload was accepted';
    exception when sqlstate '23505' then null;
    end;
end
$verify$;

rollback;
