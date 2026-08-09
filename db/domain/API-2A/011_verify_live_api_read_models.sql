-- MoneyTrack — API-2A — Live API Read Models verifier
-- Read-only / rollback-safe validation of signatures and representative semantics.

begin;

-- Signature gate.
do $verify_signatures$
begin
    if to_regprocedure('moneytrack.api_transactions_read_model_v1(bigint,text,date,date,boolean)') is null then
        raise exception 'missing api_transactions_read_model_v1';
    end if;

    if to_regprocedure('moneytrack.api_accounts_explorer_summary_read_model_v1(bigint,bigint[],date,date,date)') is null then
        raise exception 'missing api_accounts_explorer_summary_read_model_v1';
    end if;

    if to_regprocedure('moneytrack.api_transaction_reference_read_model_v1(bigint)') is null then
        raise exception 'missing api_transaction_reference_read_model_v1';
    end if;
end;
$verify_signatures$;

-- Representative existing-user semantics.
do $verify_existing_user$
declare
    v_telegram_user_id bigint;
    v_user_id bigint;
    v_account_id bigint;
    v_account_currency text;
    v_base_currency text;
    v_ref record;
    v_tx record;
    v_summary record;
begin
    select u.telegram_user_id, u.id,
           coalesce(s.base_currency, u.default_currency, 'EUR')::text
      into v_telegram_user_id, v_user_id, v_base_currency
    from moneytrack.app_users u
    left join moneytrack.user_settings s on s.user_id = u.id
    where u.telegram_user_id is not null
    order by u.id
    limit 1;

    if v_telegram_user_id is null then
        raise exception 'API-2A verifier requires at least one existing Telegram user';
    end if;

    select a.id, a.currency_code
      into v_account_id, v_account_currency
    from moneytrack.accounts a
    where a.user_id = v_user_id
      and a.is_active = true
    order by a.id
    limit 1;

    if v_account_id is null then
        raise exception 'API-2A verifier requires at least one active account for user %', v_user_id;
    end if;

    select * into v_ref
    from moneytrack.api_transaction_reference_read_model_v1(v_telegram_user_id);

    if v_ref.user_found is distinct from true then
        raise exception 'transaction reference did not resolve existing user';
    end if;

    if jsonb_typeof(v_ref.currencies) <> 'array'
       or jsonb_typeof(v_ref.categories) <> 'array' then
        raise exception 'transaction reference arrays malformed';
    end if;

    select * into v_tx
    from moneytrack.api_transactions_read_model_v1(
        v_telegram_user_id,
        v_account_id::text,
        current_date - 30,
        current_date,
        false
    );

    if v_tx.user_id is distinct from v_user_id then
        raise exception 'transactions read model user mismatch';
    end if;

    if v_tx.account_scope_count <> 1 then
        raise exception 'leaf/no-descendants scope should equal 1, got %', v_tx.account_scope_count;
    end if;

    if v_tx.summary_currency is distinct from v_account_currency then
        raise exception 'leaf summary currency mismatch: expected %, got %', v_account_currency, v_tx.summary_currency;
    end if;

    if v_tx.result is distinct from (v_tx.income - v_tx.expense) then
        raise exception 'transactions result invariant failed';
    end if;

    if jsonb_typeof(v_tx.transactions) <> 'array' then
        raise exception 'transactions payload is not an array';
    end if;

    select * into v_summary
    from moneytrack.api_accounts_explorer_summary_read_model_v1(
        v_telegram_user_id,
        '{}'::bigint[],
        current_date - 30,
        current_date,
        current_date
    );

    if v_summary.user_id is distinct from v_user_id then
        raise exception 'explorer summary user mismatch';
    end if;

    if v_summary.base_currency is distinct from v_base_currency then
        raise exception 'explorer summary base currency mismatch';
    end if;

    if v_summary.period_result is distinct from (v_summary.period_income - v_summary.period_expense) then
        raise exception 'explorer period result invariant failed';
    end if;

    if v_summary.included_account_count < 0 then
        raise exception 'explorer included account count invalid';
    end if;
end;
$verify_existing_user$;

-- Unknown-user compatibility.
do $verify_unknown_user$
declare
    v_missing bigint := -9223372036854775807;
    v_count bigint;
    v_ref record;
begin
    select count(*) into v_count
    from moneytrack.api_transactions_read_model_v1(
        v_missing, '1', current_date - 1, current_date, true
    );
    if v_count <> 0 then
        raise exception 'unknown user unexpectedly returned transactions row';
    end if;

    select count(*) into v_count
    from moneytrack.api_accounts_explorer_summary_read_model_v1(
        v_missing, '{}'::bigint[], current_date - 1, current_date, current_date
    );
    if v_count <> 0 then
        raise exception 'unknown user unexpectedly returned explorer summary row';
    end if;

    select * into v_ref
    from moneytrack.api_transaction_reference_read_model_v1(v_missing);
    if v_ref.user_found is distinct from false then
        raise exception 'unknown user reference should report user_found=false';
    end if;
end;
$verify_unknown_user$;

-- No writes are expected; rollback keeps the verifier contract explicit.
rollback;

\echo 'API-2A verifier PASS: signatures, existing-user read contracts, ownership isolation and unknown-user behavior preserved'
