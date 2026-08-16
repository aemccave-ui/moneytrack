-- MoneyTrack — SPC-001B — Space lifecycle / membership / invites
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- Financial authorization remains assert_space_member_v1. Owner checks below are
-- administration-only. Raw invite tokens are generated and SHA-256 hashed by the
-- trusted Node/n8n adapter; PostgreSQL receives/stores token_hash only.

begin;

alter table moneytrack.workspaces
    add column if not exists updated_at timestamptz,
    add column if not exists archived_at timestamptz;

alter table moneytrack.workspace_members
    add column if not exists joined_at timestamptz,
    add column if not exists invited_by_user_id bigint references moneytrack.app_users(id) on delete set null,
    add column if not exists removed_at timestamptz;

update moneytrack.workspace_members
   set joined_at = coalesce(joined_at, created_at, now())
 where joined_at is null;

alter table moneytrack.user_settings
    add column if not exists default_capture_space_id bigint
        references moneytrack.workspaces(id) on delete set null;

create table if not exists moneytrack.space_invites (
    id bigserial primary key,
    space_id bigint not null references moneytrack.workspaces(id) on delete cascade,
    token_hash text not null unique,
    created_by_user_id bigint references moneytrack.app_users(id) on delete set null,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null,
    accepted_by_user_id bigint references moneytrack.app_users(id) on delete set null,
    accepted_at timestamptz,
    revoked_at timestamptz,
    constraint ck_spc001_invite_hash_sha256
        check (token_hash ~ '^[0-9A-Fa-f]{64}$'),
    constraint ck_spc001_invite_expiry_after_create
        check (expires_at > created_at)
);

create index if not exists ix_spc001_space_invites_space_active
    on moneytrack.space_invites(space_id, expires_at, id)
    where accepted_at is null and revoked_at is null;

-- ---------------------------------------------------------------------------
-- Current/default Space pointers are preferences, never authorization claims.
-- Any non-null pointer must still reference an active membership.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.spc001_assert_user_space_pointer_v1()
returns trigger
language plpgsql
as $function$
begin
    if new.user_id = 0 then
        return new;
    end if;

    if new.current_workspace_id is not null then
        perform moneytrack.assert_space_member_v1(new.user_id,new.current_workspace_id);
    end if;

    if new.default_capture_space_id is not null then
        perform moneytrack.assert_space_member_v1(new.user_id,new.default_capture_space_id);
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_spc001_user_space_pointer on moneytrack.user_settings;
create trigger trg_spc001_user_space_pointer
before insert or update of current_workspace_id,default_capture_space_id
on moneytrack.user_settings
for each row execute function moneytrack.spc001_assert_user_space_pointer_v1();

-- Existing users default Bot capture to an explicit accessible Space. Prefer the
-- existing current Space only if membership is active; otherwise use Personal.
update moneytrack.user_settings us
   set default_capture_space_id = coalesce(
       case when exists (
           select 1 from moneytrack.workspace_members wm
           join moneytrack.workspaces w on w.id=wm.workspace_id
           where wm.workspace_id=us.current_workspace_id
             and wm.user_id=us.user_id
             and coalesce(wm.is_active,true)=true
             and coalesce(w.is_active,true)=true
       ) then us.current_workspace_id end,
       (
           select w.id
           from moneytrack.workspaces w
           join moneytrack.workspace_members wm
             on wm.workspace_id=w.id
            and wm.user_id=us.user_id
            and coalesce(wm.is_active,true)=true
           where w.owner_user_id=us.user_id
             and w.workspace_type='personal'
             and coalesce(w.is_active,true)=true
           order by w.id
           limit 1
       )
   ),
       updated_at=now()
 where us.user_id<>0
   and us.default_capture_space_id is null;

-- ---------------------------------------------------------------------------
-- Accessible Space read model.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.space_list_v1(p_actor_user_id bigint)
returns table (
    space_id bigint,
    name text,
    owner_user_id bigint,
    is_owner boolean,
    is_active boolean,
    member_count bigint
)
language plpgsql
stable
as $function$
begin
    if p_actor_user_id is null then
        raise exception 'ACTOR_REQUIRED' using errcode='22023';
    end if;

    return query
    select
        w.id,
        w.name,
        w.owner_user_id,
        w.owner_user_id=p_actor_user_id,
        coalesce(w.is_active,true),
        (
            select count(*)
            from moneytrack.workspace_members members
            where members.workspace_id=w.id
              and coalesce(members.is_active,true)=true
        )
    from moneytrack.workspaces w
    join moneytrack.workspace_members wm
      on wm.workspace_id=w.id
     and wm.user_id=p_actor_user_id
     and coalesce(wm.is_active,true)=true
    where coalesce(w.is_active,true)=true
    order by (w.owner_user_id=p_actor_user_id) desc,w.id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Owner-only administration. Ordinary financial CRUD never calls owner assert.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.space_create_v1(
    p_actor_user_id bigint,
    p_name text
)
returns table(space_id bigint,name text)
language plpgsql
volatile
as $function$
declare
    v_space_id bigint;
    v_name text:=nullif(btrim(p_name),'');
begin
    if p_actor_user_id is null then raise exception 'ACTOR_REQUIRED' using errcode='22023'; end if;
    if v_name is null then raise exception 'SPACE_NAME_REQUIRED' using errcode='22023'; end if;
    if length(v_name)>120 then raise exception 'SPACE_NAME_TOO_LONG' using errcode='22023'; end if;

    if not exists (select 1 from moneytrack.app_users u where u.id=p_actor_user_id) then
        raise exception 'ACTOR_NOT_FOUND' using errcode='P0002';
    end if;

    insert into moneytrack.workspaces(
        name,workspace_type,owner_user_id,is_active,created_at,updated_at
    ) values (
        v_name,'shared',p_actor_user_id,true,now(),now()
    ) returning id into v_space_id;

    insert into moneytrack.workspace_members(
        workspace_id,user_id,role,is_active,created_at,joined_at,invited_by_user_id,removed_at
    ) values (
        v_space_id,p_actor_user_id,'owner',true,now(),now(),p_actor_user_id,null
    )
    on conflict (workspace_id,user_id) do update
       set role='owner',is_active=true,joined_at=coalesce(moneytrack.workspace_members.joined_at,now()),removed_at=null;

    perform 1 from moneytrack.spc001_bootstrap_space_finance_v1(p_actor_user_id,v_space_id);

    return query select v_space_id,v_name;
end;
$function$;

comment on function moneytrack.space_create_v1(bigint,text)
is 'SPC-001 creates a new independent financial Space. Owner is also an active member; owner status grants administration only.';

create or replace function moneytrack.space_rename_v1(
    p_actor_user_id bigint,p_space_id bigint,p_name text
)
returns text
language plpgsql
volatile
as $function$
declare v_name text:=nullif(btrim(p_name),'');
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);
    if v_name is null then raise exception 'SPACE_NAME_REQUIRED' using errcode='22023'; end if;
    update moneytrack.workspaces
       set name=v_name,updated_at=now()
     where id=p_space_id and coalesce(is_active,true)=true;
    return v_name;
end;
$function$;

create or replace function moneytrack.space_archive_v1(
    p_actor_user_id bigint,p_space_id bigint
)
returns text
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);

    update moneytrack.workspaces
       set is_active=false,archived_at=now(),updated_at=now()
     where id=p_space_id;

    -- Clear preferences first; no financial value from the archived Space is
    -- returned by this administrative boundary.
    update moneytrack.user_settings
       set current_workspace_id=null,updated_at=now()
     where current_workspace_id=p_space_id;
    update moneytrack.user_settings
       set default_capture_space_id=null,updated_at=now()
     where default_capture_space_id=p_space_id;

    return 'archived';
end;
$function$;

-- ---------------------------------------------------------------------------
-- Active Space and Bot default capture Space.
-- Switching only changes the pointer. MiniApp must clear old Space state FIRST
-- and then load the new Space; this DB function returns no old financial data.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.space_set_active_v1(
    p_actor_user_id bigint,p_space_id bigint
)
returns bigint
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    update moneytrack.user_settings
       set current_workspace_id=p_space_id,updated_at=now()
     where user_id=p_actor_user_id;
    if not found then raise exception 'USER_SETTINGS_NOT_FOUND' using errcode='P0002'; end if;
    return p_space_id;
end;
$function$;

create or replace function moneytrack.space_set_default_capture_v1(
    p_actor_user_id bigint,p_space_id bigint
)
returns bigint
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    update moneytrack.user_settings
       set default_capture_space_id=p_space_id,updated_at=now()
     where user_id=p_actor_user_id;
    if not found then raise exception 'USER_SETTINGS_NOT_FOUND' using errcode='P0002'; end if;
    return p_space_id;
end;
$function$;

create or replace function moneytrack.space_resolve_default_capture_v1(
    p_actor_user_id bigint
)
returns bigint
language plpgsql
stable
as $function$
declare v_space_id bigint;
begin
    select us.default_capture_space_id into v_space_id
      from moneytrack.user_settings us
     where us.user_id=p_actor_user_id;

    if v_space_id is null then
        raise exception 'DEFAULT_CAPTURE_SPACE_REQUIRED' using errcode='P0002';
    end if;

    -- Deliberately do NOT use current_workspace_id or last active MiniApp Space.
    perform moneytrack.assert_space_member_v1(p_actor_user_id,v_space_id);
    return v_space_id;
end;
$function$;

comment on function moneytrack.space_resolve_default_capture_v1(bigint)
is 'SPC-001 Bot destination resolver. Uses explicit default_capture_space_id only; never last active MiniApp Space.';

-- ---------------------------------------------------------------------------
-- Telegram invite lifecycle. token_hash is an opaque SHA-256 digest supplied by
-- the trusted adapter; raw token and authorization claims are never persisted.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.space_invite_create_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_token_hash text,
    p_expires_at timestamptz
)
returns table(invite_id bigint,space_id bigint,expires_at timestamptz)
language plpgsql
volatile
as $function$
declare v_id bigint;
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);
    if p_token_hash is null or p_token_hash !~ '^[0-9A-Fa-f]{64}$' then
        raise exception 'INVITE_TOKEN_HASH_INVALID' using errcode='22023';
    end if;
    if p_expires_at is null or p_expires_at<=now() then
        raise exception 'INVITE_EXPIRY_INVALID' using errcode='22023';
    end if;

    insert into moneytrack.space_invites(
        space_id,token_hash,created_by_user_id,created_at,expires_at
    ) values (
        p_space_id,lower(p_token_hash),p_actor_user_id,now(),p_expires_at
    ) returning id into v_id;

    return query select v_id,p_space_id,p_expires_at;
end;
$function$;

create or replace function moneytrack.space_invite_revoke_v1(
    p_actor_user_id bigint,p_invite_id bigint
)
returns text
language plpgsql
volatile
as $function$
declare v_space_id bigint;
begin
    select i.space_id into v_space_id
      from moneytrack.space_invites i
     where i.id=p_invite_id
     for update;
    if v_space_id is null then raise exception 'INVITE_NOT_FOUND' using errcode='P0002'; end if;
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,v_space_id);

    update moneytrack.space_invites
       set revoked_at=coalesce(revoked_at,now())
     where id=p_invite_id and accepted_at is null;
    return 'revoked';
end;
$function$;

create or replace function moneytrack.space_invite_accept_v1(
    p_actor_user_id bigint,
    p_token_hash text
)
returns table(space_id bigint,status text)
language plpgsql
volatile
as $function$
declare
    v_invite moneytrack.space_invites%rowtype;
begin
    if p_actor_user_id is null then raise exception 'ACTOR_REQUIRED' using errcode='22023'; end if;
    if p_token_hash is null or p_token_hash !~ '^[0-9A-Fa-f]{64}$' then
        raise exception 'INVITE_TOKEN_INVALID' using errcode='22023';
    end if;

    select i.* into v_invite
      from moneytrack.space_invites i
     where i.token_hash=lower(p_token_hash)
     for update;

    if not found then raise exception 'INVITE_INVALID' using errcode='P0002'; end if;
    if v_invite.revoked_at is not null then raise exception 'INVITE_REVOKED' using errcode='22023'; end if;
    if v_invite.accepted_at is not null then raise exception 'INVITE_ALREADY_USED' using errcode='23505'; end if;
    if v_invite.expires_at<=now() then raise exception 'INVITE_EXPIRED' using errcode='22023'; end if;

    if not exists (
        select 1 from moneytrack.workspaces w
        where w.id=v_invite.space_id and coalesce(w.is_active,true)=true
    ) then raise exception 'INVITE_SPACE_INACTIVE' using errcode='P0002'; end if;

    insert into moneytrack.workspace_members(
        workspace_id,user_id,role,is_active,created_at,joined_at,invited_by_user_id,removed_at
    ) values (
        v_invite.space_id,p_actor_user_id,'member',true,now(),now(),v_invite.created_by_user_id,null
    )
    on conflict (workspace_id,user_id) do update
       set role=case when moneytrack.workspace_members.role='owner' then 'owner' else 'member' end,
           is_active=true,
           joined_at=now(),
           invited_by_user_id=excluded.invited_by_user_id,
           removed_at=null;

    update moneytrack.space_invites
       set accepted_by_user_id=p_actor_user_id,accepted_at=now()
     where id=v_invite.id;

    return query select v_invite.space_id,'accepted'::text;
end;
$function$;

-- A new Telegram identity can bootstrap its own Personal Space and then accept
-- an invite in the same transaction. Adapter must authenticate Telegram InitData
-- and SHA-256 the opaque raw token before calling this boundary.
create or replace function moneytrack.space_invite_accept_telegram_v1(
    p_telegram_user_id bigint,
    p_username text,
    p_first_name text,
    p_telegram_language_code text,
    p_token_hash text
)
returns table(user_id bigint,space_id bigint,status text)
language plpgsql
volatile
as $function$
declare
    v_boot record;
    v_accept record;
begin
    select * into v_boot
      from moneytrack.spc001_user_bootstrap_v1(
          p_telegram_user_id,p_username,p_first_name,p_telegram_language_code
      );

    select * into v_accept
      from moneytrack.space_invite_accept_v1(v_boot.user_id,p_token_hash);

    return query select v_boot.user_id,v_accept.space_id,v_accept.status;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Member administration. Removal revokes access on the very next request because
-- assert_space_member_v1 reads current membership state; unlock tokens contain no
-- membership list. Authored shared financial history is untouched.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.space_remove_member_v1(
    p_actor_user_id bigint,p_space_id bigint,p_member_user_id bigint
)
returns text
language plpgsql
volatile
as $function$
declare v_fallback bigint;
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);

    if p_member_user_id=p_actor_user_id then
        raise exception 'OWNER_CANNOT_REMOVE_SELF' using errcode='22023';
    end if;
    if exists (
        select 1 from moneytrack.workspaces w
        where w.id=p_space_id and w.owner_user_id=p_member_user_id
    ) then raise exception 'SPACE_OWNER_CANNOT_BE_REMOVED' using errcode='22023'; end if;

    update moneytrack.workspace_members
       set is_active=false,removed_at=now()
     where workspace_id=p_space_id
       and user_id=p_member_user_id
       and coalesce(is_active,true)=true;
    if not found then raise exception 'MEMBER_NOT_FOUND' using errcode='P0002'; end if;

    select w.id into v_fallback
      from moneytrack.workspaces w
      join moneytrack.workspace_members wm
        on wm.workspace_id=w.id
       and wm.user_id=p_member_user_id
       and coalesce(wm.is_active,true)=true
     where w.owner_user_id=p_member_user_id
       and w.workspace_type='personal'
       and coalesce(w.is_active,true)=true
     order by w.id limit 1;

    update moneytrack.user_settings
       set current_workspace_id=case when current_workspace_id=p_space_id then v_fallback else current_workspace_id end,
           default_capture_space_id=case when default_capture_space_id=p_space_id then v_fallback else default_capture_space_id end,
           updated_at=now()
     where user_id=p_member_user_id;

    return 'removed';
end;
$function$;

create or replace function moneytrack.space_member_list_v1(
    p_actor_user_id bigint,p_space_id bigint
)
returns table(user_id bigint,role text,joined_at timestamptz,is_active boolean)
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);
    return query
    select wm.user_id,wm.role,coalesce(wm.joined_at,wm.created_at),coalesce(wm.is_active,true)
    from moneytrack.workspace_members wm
    where wm.workspace_id=p_space_id
    order by (wm.role='owner') desc,coalesce(wm.joined_at,wm.created_at),wm.user_id;
end;
$function$;

commit;
