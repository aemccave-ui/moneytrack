-- MoneyTrack — SPC-001B — lifecycle / invite / erasure verifier
--
-- Run after SPC-001A + 110 + 120 in a controlled dry-run database.
-- All synthetic state is rolled back.

begin;

do $lifecycle_fixture$
declare
    v_owner record;
    v_member record;
    v_new_member record;
    v_space bigint;
    v_personal bigint;
    v_account bigint;
    v_tx moneytrack.transactions%rowtype;
    v_invite record;
    v_delete_req record;
    v_delete_result record;
    v_rejected boolean;
    v_hash1 text:=repeat('a',64);
    v_hash2 text:=repeat('b',64);
    v_hash3 text:=repeat('c',64);
    v_hash4 text:=repeat('d',64);
    v_currency text;
begin
    select * into v_owner
      from moneytrack.spc001_user_bootstrap_v1(-920000001,'spc_owner','SPC Owner','en');
    select * into v_member
      from moneytrack.spc001_user_bootstrap_v1(-920000002,'spc_member','SPC Member','en');

    v_personal:=v_owner.space_id;
    select s.space_id into v_space
      from moneytrack.space_create_v1(v_owner.user_id,'SPC Family') s;

    -- Owner administration is distinct from finance membership.
    perform moneytrack.assert_space_owner_v1(v_owner.user_id,v_space);
    perform moneytrack.assert_space_member_v1(v_owner.user_id,v_space);

    -- Valid invite: B joins.
    select * into v_invite
      from moneytrack.space_invite_create_v1(
          v_owner.user_id,v_space,v_hash1,now()+interval '1 hour'
      );
    perform moneytrack.space_invite_accept_v1(v_member.user_id,v_hash1);
    perform moneytrack.assert_space_member_v1(v_member.user_id,v_space);

    -- Single-use invite.
    v_rejected:=false;
    begin
        perform moneytrack.space_invite_accept_v1(v_member.user_id,v_hash1);
    exception when others then
        if sqlerrm like '%INVITE_ALREADY_USED%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_INVITE_REUSE_NOT_REJECTED'; end if;

    -- Revoked invite.
    select * into v_invite
      from moneytrack.space_invite_create_v1(
          v_owner.user_id,v_space,v_hash2,now()+interval '1 hour'
      );
    perform moneytrack.space_invite_revoke_v1(v_owner.user_id,v_invite.invite_id);
    v_rejected:=false;
    begin
        perform moneytrack.space_invite_accept_v1(v_member.user_id,v_hash2);
    exception when others then
        if sqlerrm like '%INVITE_REVOKED%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_REVOKED_INVITE_NOT_REJECTED'; end if;

    -- Expired invite fixture satisfies expires_at > created_at but is already old.
    insert into moneytrack.space_invites(
        space_id,token_hash,created_by_user_id,created_at,expires_at
    ) values (
        v_space,v_hash3,v_owner.user_id,now()-interval '2 hours',now()-interval '1 hour'
    );
    v_rejected:=false;
    begin
        perform moneytrack.space_invite_accept_v1(v_member.user_id,v_hash3);
    exception when others then
        if sqlerrm like '%INVITE_EXPIRED%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_EXPIRED_INVITE_NOT_REJECTED'; end if;

    -- Manipulated/unknown token hash.
    v_rejected:=false;
    begin
        perform moneytrack.space_invite_accept_v1(v_member.user_id,repeat('e',64));
    exception when others then
        if sqlerrm like '%INVITE_INVALID%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_MANIPULATED_INVITE_NOT_REJECTED'; end if;

    -- New Telegram identity needs no owner-side precreation: bootstrap + accept is
    -- one backend transaction after adapter-authenticated Telegram identity.
    select * into v_invite
      from moneytrack.space_invite_create_v1(
          v_owner.user_id,v_space,v_hash4,now()+interval '1 hour'
      );
    select * into v_new_member
      from moneytrack.space_invite_accept_telegram_v1(
          -920000003,'spc_new','SPC New','en',v_hash4
      );
    perform moneytrack.assert_space_member_v1(v_new_member.user_id,v_space);

    -- Explicit Bot default is independent of current/last-active MiniApp Space.
    perform moneytrack.space_set_default_capture_v1(v_owner.user_id,v_space);
    perform moneytrack.space_set_active_v1(v_owner.user_id,v_personal);
    if moneytrack.space_resolve_default_capture_v1(v_owner.user_id)<>v_space then
        raise exception 'SPC001_BOT_DEFAULT_FOLLOWED_ACTIVE_SPACE';
    end if;

    -- A non-owner active member has ordinary financial rights.
    select s.base_currency into v_currency
      from moneytrack.space_financial_settings s where s.space_id=v_space;
    select a.id into v_account
      from moneytrack.accounts a
     where a.space_id=v_space and coalesce(a.is_active,true)=true
     order by a.id limit 1;

    v_tx:=moneytrack.finance_create_transaction_space_v1(
        v_member.user_id,v_space,v_account,'expense',12,v_currency,
        'member-authored shared history',now(),null,null,null
    );

    -- Member erasure preserves the shared transaction and Space. The legacy
    -- actor pointers become NULL through SPC-001A ON DELETE SET NULL FKs.
    select * into v_delete_req
      from moneytrack.user_create_delete_request_v1(v_member.user_id);
    select * into v_delete_result
      from moneytrack.user_delete_me_v1(v_member.user_id,v_delete_req.confirmation_code);

    if v_delete_result.status<>'deleted' then
        raise exception 'SPC001_MEMBER_ERASURE_FAILED';
    end if;
    if not exists (
        select 1 from moneytrack.transactions t where t.id=v_tx.id and t.space_id=v_space
    ) then
        raise exception 'SPC001_MEMBER_ERASURE_DELETED_SHARED_HISTORY';
    end if;
    if exists (select 1 from moneytrack.app_users u where u.id=v_member.user_id) then
        raise exception 'SPC001_MEMBER_IDENTITY_NOT_ERASED';
    end if;
    if exists (
        select 1 from moneytrack.transactions t
        where t.id=v_tx.id and (t.user_id is not null or t.created_by_user_id is not null)
    ) then
        raise exception 'SPC001_MEMBER_ERASURE_ACTOR_POINTER_NOT_NULL';
    end if;

    -- Removal of another active member invalidates the next request immediately.
    perform moneytrack.space_remove_member_v1(
        v_owner.user_id,v_space,v_new_member.user_id
    );
    v_rejected:=false;
    begin
        perform moneytrack.finance_transactions_space_read_model_v1(
            v_new_member.user_id,v_space,current_date-1,current_date+1
        );
    exception when others then
        if sqlerrm like '%SPACE_NOT_FOUND_OR_NOT_MEMBER%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_REMOVED_MEMBER_STILL_AUTHORIZED'; end if;

    -- Re-add C solely to prove owner deletion semantics fail closed.
    update moneytrack.workspace_members
       set is_active=true,removed_at=null,joined_at=now()
     where workspace_id=v_space and user_id=v_new_member.user_id;

    select * into v_delete_req
      from moneytrack.user_create_delete_request_v1(v_owner.user_id);
    v_rejected:=false;
    begin
        perform moneytrack.user_delete_me_v1(
            v_owner.user_id,v_delete_req.confirmation_code
        );
    exception when others then
        if sqlerrm like '%OWNER_DELETION_REQUIRES_TRANSFER%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_OWNER_ERASURE_DID_NOT_FAIL_CLOSED'; end if;
    if not exists (select 1 from moneytrack.app_users u where u.id=v_owner.user_id) then
        raise exception 'SPC001_OWNER_ERASURE_MUTATED_IDENTITY_BEFORE_FAIL';
    end if;
    if not exists (select 1 from moneytrack.workspaces w where w.id=v_space) then
        raise exception 'SPC001_OWNER_ERASURE_MUTATED_SPACE_BEFORE_FAIL';
    end if;

    raise notice 'SPACE_LIFECYCLE=PASS';
    raise notice 'INVITE_SINGLE_USE_EXPIRY_REVOKE=PASS';
    raise notice 'INVITE_NEW_TELEGRAM_BOOTSTRAP=PASS';
    raise notice 'BOT_DEFAULT_CAPTURE_SPACE_EXPLICIT=PASS';
    raise notice 'MEMBER_REMOVAL_IMMEDIATE=PASS';
    raise notice 'MEMBER_ERASURE_SHARED_HISTORY=PASS';
    raise notice 'OWNER_ERASURE_FAIL_CLOSED=PASS';
end;
$lifecycle_fixture$;

rollback;
