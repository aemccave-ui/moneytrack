-- MoneyTrack — BE-DOM-001 — canonical user erasure boundary
--
-- Account/user deletion is a destructive cross-domain lifecycle operation.
-- n8n passes authenticated user id + confirmation code only; validation,
-- referential cleanup and deletion ordering live in PostgreSQL.

begin;

create or replace function moneytrack.user_delete_me_v1(
    p_user_id bigint,
    p_confirmation_code text
)
returns table (
    status text,
    deleted_user_id bigint,
    deleted_transaction_count bigint,
    deleted_transfer_count bigint,
    deleted_workspace_count bigint
)
language plpgsql
volatile
as $function$
declare
    v_request_id bigint;
    v_owned_workspace_ids bigint[] := '{}'::bigint[];
    v_deleted_transactions bigint := 0;
    v_deleted_transfers bigint := 0;
    v_deleted_workspaces bigint := 0;
    v_deleted_user bigint;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if p_confirmation_code is null or btrim(p_confirmation_code) = '' then
        return query
        select 'invalid_command'::text, null::bigint, 0::bigint, 0::bigint, 0::bigint;
        return;
    end if;

    -- Lock the newest still-valid request. This makes concurrent confirmation
    -- attempts serialize at the backend boundary.
    select r.id
      into v_request_id
      from moneytrack.user_delete_requests r
     where r.user_id = p_user_id
       and r.confirmation_code = p_confirmation_code
       and r.used_at is null
       and r.expires_at >= now()
     order by r.created_at desc, r.id desc
     limit 1
     for update;

    if v_request_id is null then
        return query
        select 'invalid_or_expired'::text, null::bigint, 0::bigint, 0::bigint, 0::bigint;
        return;
    end if;

    -- Preserve legacy one-time confirmation semantics even though the request
    -- itself is removed later in this same atomic transaction.
    update moneytrack.user_delete_requests
       set used_at = now()
     where id = v_request_id;

    select coalesce(array_agg(w.id order by w.id), '{}'::bigint[])
      into v_owned_workspace_ids
      from moneytrack.workspaces w
     where w.owner_user_id = p_user_id;

    -- Owned workspaces may be referenced by other users. Detach those settings
    -- before deleting the workspaces, and remove all memberships in them.
    if cardinality(v_owned_workspace_ids) > 0 then
        update moneytrack.user_settings us
           set current_workspace_id = null,
               updated_at = now()
         where us.current_workspace_id = any(v_owned_workspace_ids)
           and us.user_id <> p_user_id;

        delete from moneytrack.workspace_members wm
         where wm.workspace_id = any(v_owned_workspace_ids);
    end if;

    -- The deleting user may also be a member of workspaces owned by others.
    delete from moneytrack.workspace_members wm
     where wm.user_id = p_user_id;

    -- Receipt children must disappear before receipts, and receipts before the
    -- referenced transactions.
    delete from moneytrack.receipt_items ri
     using moneytrack.receipts r
     where ri.receipt_id = r.id
       and r.user_id = p_user_id;

    delete from moneytrack.receipts r
     where r.user_id = p_user_id;

    -- Remove category dependants before category rows.
    delete from moneytrack.budget_rules br
     where br.user_id = p_user_id;

    -- Transactions may reference transfers through transactions.transfer_id,
    -- so transactions must be removed before transfers.
    delete from moneytrack.transactions t
     where t.user_id = p_user_id;
    get diagnostics v_deleted_transactions = row_count;

    delete from moneytrack.transfers t
     where t.user_id = p_user_id;
    get diagnostics v_deleted_transfers = row_count;

    -- Account references from defaults/settings must be gone before accounts.
    delete from moneytrack.user_default_accounts uda
     where uda.user_id = p_user_id;

    delete from moneytrack.user_settings us
     where us.user_id = p_user_id;

    delete from moneytrack.product_catalog pc
     where pc.user_id = p_user_id;

    delete from moneytrack.category_catalog cc
     where cc.user_id = p_user_id;

    delete from moneytrack.accounts a
     where a.user_id = p_user_id;

    delete from moneytrack.user_currencies uc
     where uc.user_id = p_user_id;

    if cardinality(v_owned_workspace_ids) > 0 then
        delete from moneytrack.workspaces w
         where w.id = any(v_owned_workspace_ids);
        get diagnostics v_deleted_workspaces = row_count;
    end if;

    -- Delete requests are normally ON DELETE CASCADE from app_users, but remove
    -- them explicitly to keep the lifecycle aggregate obvious and self-contained.
    delete from moneytrack.user_delete_requests r
     where r.user_id = p_user_id;

    delete from moneytrack.app_users au
     where au.id = p_user_id
     returning au.id into v_deleted_user;

    if v_deleted_user is null then
        raise exception 'USER_DELETE_CONCURRENCY_FAILURE: %', p_user_id
            using errcode = 'P0001';
    end if;

    return query
    select
        'deleted'::text,
        v_deleted_user,
        v_deleted_transactions,
        v_deleted_transfers,
        v_deleted_workspaces;
end;
$function$;

comment on function moneytrack.user_delete_me_v1(bigint,text)
is 'BE-DOM-001 canonical destructive user lifecycle boundary. Validates one-time confirmation and atomically removes user-owned finance/catalog/settings/workspace data in FK-safe order while detaching other users from deleted owned workspaces.';

commit;
