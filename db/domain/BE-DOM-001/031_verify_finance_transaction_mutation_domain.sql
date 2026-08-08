-- MoneyTrack — BE-DOM-001 — transaction mutation boundary verification
-- Usage:
--   docker exec -i moneytrack-db psql -U moneytrack -d moneytrack \
--     -v ON_ERROR_STOP=1 -v user_id=1 < 031_verify_finance_transaction_mutation_domain.sql
--
-- All writes are rolled back.

begin;

create temporary table be_dom_001_mutation_verify_ctx as
select :user_id::bigint as user_id;

DO $verify$
declare
    v_user_id bigint;
    v_from_account bigint;
    v_to_account bigint;
    v_currency text;
    v_mismatch_account bigint;
    v_foreign_user bigint;
    v_foreign_account bigint;
    v_update_tx record;
    v_update_result record;
    v_delete_tx record;
    v_delete_result record;
    v_replay_result record;
    v_foreign_delete_result record;
    v_receipt_id bigint;
    v_receipt_item_id bigint;
    v_count bigint;
begin
    select user_id into v_user_id
      from be_dom_001_mutation_verify_ctx;

    if not exists (select 1 from moneytrack.app_users u where u.id = v_user_id) then
        raise exception 'VERIFY_USER_NOT_FOUND: %', v_user_id;
    end if;

    -- Account reassignment needs two owned, active accounts in the same currency.
    select a1.id, a2.id, upper(a1.currency_code)
      into v_from_account, v_to_account, v_currency
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

    if v_from_account is null or v_to_account is null then
        raise exception 'VERIFY_REQUIRES_TWO_ACTIVE_SAME_CURRENCY_ACCOUNTS';
    end if;

    select a.id
      into v_mismatch_account
      from moneytrack.accounts a
     where a.user_id = v_user_id
       and coalesce(a.is_active, true) = true
       and upper(a.currency_code) <> v_currency
     order by a.id
     limit 1;

    if v_mismatch_account is null then
        raise exception 'VERIFY_REQUIRES_ACTIVE_DIFFERENT_CURRENCY_ACCOUNT';
    end if;

    select a.user_id, a.id
      into v_foreign_user, v_foreign_account
      from moneytrack.accounts a
     where a.user_id <> v_user_id
       and coalesce(a.is_active, true) = true
     order by a.user_id, a.id
     limit 1;

    if v_foreign_account is null then
        raise exception 'VERIFY_REQUIRES_FOREIGN_ACCOUNT';
    end if;

    -- Create a canonical posting, then reassign it to another same-currency account.
    select *
      into v_update_tx
      from moneytrack.finance_create_transaction_v1(
          v_user_id,
          v_from_account,
          'expense',
          3.21,
          v_currency,
          'BE-DOM-001 mutation update verification',
          now(),
          'be_dom_001_mutation_verify',
          930001,
          null
      );

    select *
      into v_update_result
      from moneytrack.finance_update_transaction_account_v1(
          v_user_id,
          v_update_tx.id,
          v_to_account
      );

    if v_update_result.id <> v_update_tx.id
       or v_update_result.account_id <> v_to_account
       or upper(v_update_result.currency_original) <> v_currency
       or v_update_result.status <> 'updated'
    then
        raise exception 'VERIFY_ACCOUNT_UPDATE_FAILED: %', row_to_json(v_update_result);
    end if;

    select count(*)
      into v_count
      from moneytrack.transactions t
     where t.id = v_update_tx.id
       and t.user_id = v_user_id
       and t.account_id = v_to_account;

    if v_count <> 1 then
        raise exception 'VERIFY_ACCOUNT_UPDATE_NOT_PERSISTED';
    end if;

    -- The backend must reject reassignment to an owned account in another currency.
    begin
        perform *
          from moneytrack.finance_update_transaction_account_v1(
              v_user_id,
              v_update_tx.id,
              v_mismatch_account
          );
        raise exception 'VERIFY_CURRENCY_MISMATCH_WAS_ACCEPTED';
    exception when sqlstate '22023' then
        if sqlerrm not like 'ACCOUNT_CURRENCY_MISMATCH:%' then
            raise;
        end if;
    end;

    -- The backend must reject an account owned by another user.
    begin
        perform *
          from moneytrack.finance_update_transaction_account_v1(
              v_user_id,
              v_update_tx.id,
              v_foreign_account
          );
        raise exception 'VERIFY_FOREIGN_ACCOUNT_WAS_ACCEPTED';
    exception when sqlstate 'P0002' then
        null;
    end;

    -- The backend must reject an unknown/non-owned transaction.
    begin
        perform *
          from moneytrack.finance_update_transaction_account_v1(
              v_user_id,
              -9223372036854770000,
              v_to_account
          );
        raise exception 'VERIFY_UNKNOWN_TRANSACTION_WAS_ACCEPTED';
    exception when sqlstate 'P0002' then
        null;
    end;

    -- Build a transaction with a receipt aggregate so delete verifies all three layers.
    select *
      into v_delete_tx
      from moneytrack.finance_create_transaction_v1(
          v_user_id,
          v_from_account,
          'expense',
          4.56,
          v_currency,
          'BE-DOM-001 mutation delete verification',
          now(),
          'be_dom_001_mutation_verify',
          930002,
          null
      );

    insert into moneytrack.receipts(
        user_id,
        receipt_fingerprint,
        transaction_id,
        telegram_file_id,
        receipt_date,
        shop_name,
        total_amount,
        currency,
        raw_ai_json,
        status
    ) values (
        v_user_id,
        'be_dom_001_mutation_verify_' || v_delete_tx.id::text,
        v_delete_tx.id,
        'be_dom_001_mutation_verify_file_' || v_delete_tx.id::text,
        current_date,
        'BE-DOM-001 Verify',
        4.56,
        v_currency,
        '{}'::jsonb,
        'parsed'
    )
    returning id into v_receipt_id;

    insert into moneytrack.receipt_items(
        receipt_id,
        item_name_original,
        item_language,
        quantity,
        unit_price,
        amount,
        category_id,
        product_id
    ) values (
        v_receipt_id,
        'BE-DOM-001 verify item',
        'en',
        1,
        4.56,
        4.56,
        null,
        null
    )
    returning id into v_receipt_item_id;

    -- Wrong user must not be able to delete the transaction and must not learn
    -- whether it exists: the canonical result is simply not_found.
    select *
      into v_foreign_delete_result
      from moneytrack.finance_delete_transaction_v1(
          v_foreign_user,
          v_delete_tx.id
      );

    if v_foreign_delete_result.deleted
       or v_foreign_delete_result.status <> 'not_found'
    then
        raise exception 'VERIFY_FOREIGN_DELETE_WAS_NOT_HIDDEN: %', row_to_json(v_foreign_delete_result);
    end if;

    if not exists (
        select 1 from moneytrack.transactions t
         where t.id = v_delete_tx.id and t.user_id = v_user_id
    ) then
        raise exception 'VERIFY_FOREIGN_DELETE_REMOVED_TRANSACTION';
    end if;

    select *
      into v_delete_result
      from moneytrack.finance_delete_transaction_v1(
          v_user_id,
          v_delete_tx.id
      );

    if not v_delete_result.deleted
       or v_delete_result.status <> 'deleted'
       or v_delete_result.transaction_id <> v_delete_tx.id
       or v_delete_result.deleted_receipt_count <> 1
       or v_delete_result.deleted_receipt_item_count <> 1
    then
        raise exception 'VERIFY_AGGREGATE_DELETE_FAILED: %', row_to_json(v_delete_result);
    end if;

    if exists (select 1 from moneytrack.transactions t where t.id = v_delete_tx.id) then
        raise exception 'VERIFY_DELETE_LEFT_TRANSACTION';
    end if;

    if exists (select 1 from moneytrack.receipts r where r.id = v_receipt_id) then
        raise exception 'VERIFY_DELETE_LEFT_RECEIPT';
    end if;

    if exists (select 1 from moneytrack.receipt_items ri where ri.id = v_receipt_item_id) then
        raise exception 'VERIFY_DELETE_LEFT_RECEIPT_ITEM';
    end if;

    -- Repeated delete is safe and deterministic.
    select *
      into v_replay_result
      from moneytrack.finance_delete_transaction_v1(
          v_user_id,
          v_delete_tx.id
      );

    if v_replay_result.deleted
       or v_replay_result.status <> 'not_found'
       or v_replay_result.deleted_receipt_count <> 0
       or v_replay_result.deleted_receipt_item_count <> 0
    then
        raise exception 'VERIFY_DELETE_REPLAY_FAILED: %', row_to_json(v_replay_result);
    end if;
end;
$verify$;

rollback;
