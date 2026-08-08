-- MoneyTrack — BE-DOM-001 — canonical transaction mutation boundary
--
-- n8n/adapters may resolve user intent, but transaction mutation invariants live here.
-- This migration introduces canonical account reassignment and aggregate transaction delete.

begin;

create or replace function moneytrack.finance_update_transaction_account_v1(
    p_user_id bigint,
    p_transaction_id bigint,
    p_account_id bigint
)
returns table (
    id bigint,
    user_id bigint,
    account_id bigint,
    account_name text,
    account_code text,
    currency_original text,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_tx moneytrack.transactions%rowtype;
    v_account moneytrack.accounts%rowtype;
    v_updated moneytrack.transactions%rowtype;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if p_transaction_id is null then
        raise exception 'TRANSACTION_REQUIRED' using errcode = '22023';
    end if;

    if p_account_id is null then
        raise exception 'ACCOUNT_REQUIRED' using errcode = '22023';
    end if;

    select t.*
      into v_tx
      from moneytrack.transactions t
     where t.id = p_transaction_id
       and t.user_id = p_user_id
     for update;

    if not found then
        raise exception 'TRANSACTION_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    select a.*
      into v_account
      from moneytrack.accounts a
     where a.id = p_account_id
       and a.user_id = p_user_id
       and coalesce(a.is_active, true) = true;

    if not found then
        raise exception 'ACCOUNT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    -- Reassigning a posting to an account of another currency would make the
    -- transaction internally inconsistent. Currency remains backend-owned.
    if upper(v_account.currency_code) <> upper(v_tx.currency_original) then
        raise exception 'ACCOUNT_CURRENCY_MISMATCH: account %, transaction %',
            upper(v_account.currency_code), upper(v_tx.currency_original)
            using errcode = '22023';
    end if;

    update moneytrack.transactions t
       set account_id = v_account.id
     where t.id = v_tx.id
       and t.user_id = p_user_id
     returning t.* into v_updated;

    return query
    select
        v_updated.id,
        v_updated.user_id,
        v_updated.account_id,
        v_account.name,
        v_account.code,
        v_updated.currency_original,
        'updated'::text;
end;
$function$;

comment on function moneytrack.finance_update_transaction_account_v1(bigint,bigint,bigint)
is 'BE-DOM-001 canonical transaction account reassignment. Enforces transaction/account ownership, active account state and transaction/account currency consistency.';


create or replace function moneytrack.finance_delete_transaction_v1(
    p_user_id bigint,
    p_transaction_id bigint
)
returns table (
    transaction_id bigint,
    user_id bigint,
    description text,
    amount_original numeric,
    currency_original text,
    transaction_date timestamptz,
    deleted boolean,
    deleted_receipt_count bigint,
    deleted_receipt_item_count bigint,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_tx moneytrack.transactions%rowtype;
    v_deleted_tx_count bigint := 0;
    v_deleted_receipt_count bigint := 0;
    v_deleted_receipt_item_count bigint := 0;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if p_transaction_id is null then
        raise exception 'TRANSACTION_REQUIRED' using errcode = '22023';
    end if;

    -- Lock the posting so concurrent mutation/delete cannot race this aggregate delete.
    select t.*
      into v_tx
      from moneytrack.transactions t
     where t.id = p_transaction_id
       and t.user_id = p_user_id
     for update;

    if not found then
        return query
        select
            p_transaction_id,
            p_user_id,
            null::text,
            null::numeric,
            null::text,
            null::timestamptz,
            false,
            0::bigint,
            0::bigint,
            'not_found'::text;
        return;
    end if;

    -- Receipt rows form part of the transaction aggregate in the current model.
    -- Delete them inside the same backend call so the operation is atomic.
    delete from moneytrack.receipt_items ri
     using moneytrack.receipts r
     where ri.receipt_id = r.id
       and r.user_id = p_user_id
       and r.transaction_id = v_tx.id;
    get diagnostics v_deleted_receipt_item_count = row_count;

    delete from moneytrack.receipts r
     where r.user_id = p_user_id
       and r.transaction_id = v_tx.id;
    get diagnostics v_deleted_receipt_count = row_count;

    delete from moneytrack.transactions t
     where t.id = v_tx.id
       and t.user_id = p_user_id;
    get diagnostics v_deleted_tx_count = row_count;

    if v_deleted_tx_count <> 1 then
        raise exception 'TRANSACTION_DELETE_CONCURRENCY_FAILURE: %', v_tx.id
            using errcode = 'P0001';
    end if;

    return query
    select
        v_tx.id,
        v_tx.user_id,
        v_tx.description,
        v_tx.amount_original,
        v_tx.currency_original,
        v_tx.transaction_date,
        true,
        v_deleted_receipt_count,
        v_deleted_receipt_item_count,
        'deleted'::text;
end;
$function$;

comment on function moneytrack.finance_delete_transaction_v1(bigint,bigint)
is 'BE-DOM-001 canonical transaction aggregate delete. Enforces transaction ownership and atomically deletes receipt items, receipts and the transaction; repeated/missing delete returns not_found.';

commit;
