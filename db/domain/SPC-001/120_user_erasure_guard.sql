-- MoneyTrack — SPC-001B — shared-Space-safe user erasure
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- Member erasure removes future access and personal state but never deletes
-- financial history merely because the erased user authored it. Owner erasure
-- FAILS CLOSED when an owned Space still has another active member because
-- ownership-transfer semantics are intentionally unresolved in SPC-001.

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
    v_owned_space_ids bigint[] := '{}'::bigint[];
    v_blocked_space_ids bigint[] := '{}'::bigint[];
    v_deleted_transactions bigint := 0;
    v_deleted_transfers bigint := 0;
    v_deleted_workspaces bigint := 0;
    v_deleted_user bigint;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode='22023';
    end if;

    if p_confirmation_code is null or btrim(p_confirmation_code)='' then
        return query select 'invalid_command'::text,null::bigint,0::bigint,0::bigint,0::bigint;
        return;
    end if;

    select r.id into v_request_id
      from moneytrack.user_delete_requests r
     where r.user_id=p_user_id
       and r.confirmation_code=p_confirmation_code
       and r.used_at is null
       and r.expires_at>=now()
     order by r.created_at desc,r.id desc
     limit 1
     for update;

    if v_request_id is null then
        return query select 'invalid_or_expired'::text,null::bigint,0::bigint,0::bigint,0::bigint;
        return;
    end if;

    -- Freeze the ownership set before any destructive action.
    select coalesce(array_agg(w.id order by w.id),'{}'::bigint[])
      into v_owned_space_ids
      from moneytrack.workspaces w
     where w.owner_user_id=p_user_id;

    -- Ownership transfer is deliberately not invented here. Any currently
    -- shared owned Space blocks deletion before the one-time request is consumed.
    select coalesce(array_agg(w.id order by w.id),'{}'::bigint[])
      into v_blocked_space_ids
      from moneytrack.workspaces w
     where w.owner_user_id=p_user_id
       and exists (
           select 1
           from moneytrack.workspace_members wm
           where wm.workspace_id=w.id
             and wm.user_id<>p_user_id
             and coalesce(wm.is_active,true)=true
       );

    if cardinality(v_blocked_space_ids)>0 then
        raise exception 'OWNER_DELETION_REQUIRES_TRANSFER: spaces=%',
            array_to_string(v_blocked_space_ids,',')
            using errcode='55000';
    end if;

    -- Consume the one-time confirmation only after the fail-closed owner gate.
    update moneytrack.user_delete_requests
       set used_at=now()
     where id=v_request_id;

    -- Revoke the user's membership in Spaces owned by somebody else. No
    -- Space-owned finance rows are touched here.
    update moneytrack.workspace_members wm
       set is_active=false,removed_at=coalesce(wm.removed_at,now())
     where wm.user_id=p_user_id
       and not (wm.workspace_id=any(v_owned_space_ids));

    -- Delete only Spaces that this user owns and that are safe to retire because
    -- no other active member exists. Destruction is scoped by space_id, never by
    -- author/user_id.
    if cardinality(v_owned_space_ids)>0 then
        delete from moneytrack.filter_presets p
         where p.space_id=any(v_owned_space_ids);

        delete from moneytrack.receipt_items ri
        using moneytrack.receipts r
        where ri.receipt_id=r.id
          and r.space_id=any(v_owned_space_ids);

        delete from moneytrack.receipts r
         where r.space_id=any(v_owned_space_ids);

        delete from moneytrack.budget_rules b
         where b.space_id=any(v_owned_space_ids);

        delete from moneytrack.transactions t
         where t.space_id=any(v_owned_space_ids);
        get diagnostics v_deleted_transactions=row_count;

        delete from moneytrack.transfers t
         where t.space_id=any(v_owned_space_ids);
        get diagnostics v_deleted_transfers=row_count;

        delete from moneytrack.space_default_accounts d
         where d.space_id=any(v_owned_space_ids);

        delete from moneytrack.space_financial_settings s
         where s.space_id=any(v_owned_space_ids);

        delete from moneytrack.category_catalog_translations tr
        using moneytrack.category_catalog c
        where tr.category_id=c.id
          and c.space_id=any(v_owned_space_ids);

        delete from moneytrack.product_catalog p
         where p.space_id=any(v_owned_space_ids);

        delete from moneytrack.category_catalog c
         where c.space_id=any(v_owned_space_ids);

        delete from moneytrack.accounts a
         where a.space_id=any(v_owned_space_ids);

        delete from moneytrack.space_invites i
         where i.space_id=any(v_owned_space_ids);

        delete from moneytrack.workspace_members wm
         where wm.workspace_id=any(v_owned_space_ids);

        -- Any USER_SPACE_PREFERENCE pointer into a retiring owned Space must be
        -- cleared before the workspace row is deleted. This includes the erased
        -- owner itself: its user_settings row is deleted later, but its FK still
        -- participates in referential integrity at this point in the transaction.
        update moneytrack.user_settings us
           set current_workspace_id=null,updated_at=now()
         where us.current_workspace_id=any(v_owned_space_ids);
        update moneytrack.user_settings us
           set default_capture_space_id=null,updated_at=now()
         where us.default_capture_space_id=any(v_owned_space_ids);

        delete from moneytrack.workspaces w
         where w.id=any(v_owned_space_ids);
        get diagnostics v_deleted_workspaces=row_count;
    end if;

    -- USER_SPACE_PREFERENCE and USER_GLOBAL mutable state belongs to the erased
    -- identity. Shared finance does not.
    delete from moneytrack.filter_presets p where p.user_id=p_user_id;
    delete from moneytrack.user_default_accounts d where d.user_id=p_user_id;
    delete from moneytrack.user_currencies c where c.user_id=p_user_id;
    delete from moneytrack.user_settings s where s.user_id=p_user_id;
    delete from moneytrack.workspace_members wm where wm.user_id=p_user_id;
    delete from moneytrack.user_delete_requests r where r.user_id=p_user_id;

    -- Financial legacy user_id + created/updated/captured actor FKs are SET NULL
    -- by SPC-001A erasure hardening, preserving records in other users' Spaces.
    delete from moneytrack.app_users u
     where u.id=p_user_id
     returning u.id into v_deleted_user;

    if v_deleted_user is null then
        raise exception 'USER_DELETE_CONCURRENCY_FAILURE: %',p_user_id using errcode='P0001';
    end if;

    return query
    select 'deleted'::text,v_deleted_user,v_deleted_transactions,v_deleted_transfers,v_deleted_workspaces;
end;
$function$;

comment on function moneytrack.user_delete_me_v1(bigint,text)
is 'SPC-001 erasure boundary: member identity deletion preserves shared Space history; owner deletion fails closed while any owned Space has another active member. Ownership transfer remains unresolved.';

commit;
