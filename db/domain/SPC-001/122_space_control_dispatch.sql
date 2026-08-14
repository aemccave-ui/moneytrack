-- MoneyTrack — SPC-001B/C — Space lifecycle/capture control API dispatcher
-- SOURCE ONLY until controlled runtime apply.
--
-- This dispatcher contains no client-trusted authorization claims. Telegram
-- identity is first bootstrapped/resolved through the canonical SPC-compatible
-- user_bootstrap_v1. Every target Space is then checked by the delegated
-- owner/member domain boundary. Unknown route/method combinations fail closed.

begin;

create or replace function moneytrack.spc001_control_api_dispatch_v1(
    p_telegram_user_id bigint,
    p_username text,
    p_first_name text,
    p_telegram_language_code text,
    p_method text,
    p_path text,
    p_query jsonb default '{}'::jsonb,
    p_body jsonb default '{}'::jsonb,
    p_invite_token_hash text default null,
    p_invite_expires_at timestamptz default null
)
returns jsonb
language plpgsql
volatile
as $function$
declare
    v_method text:=upper(coalesce(p_method,''));
    v_path text:=ltrim(coalesce(p_path,''),'/');
    v_query jsonb:=coalesce(p_query,'{}'::jsonb);
    v_body jsonb:=coalesce(p_body,'{}'::jsonb);
    v_boot record;
    v_actor bigint;
    v_space bigint;
    v_user bigint;
    v_invite bigint;
    v_event bigint;
    v_result jsonb;
begin
    if v_path not in (
        'api/v1/spaces',
        'api/v1/spaces/archive',
        'api/v1/spaces/active',
        'api/v1/spaces/default-capture',
        'api/v1/spaces/invite',
        'api/v1/spaces/invite/revoke',
        'api/v1/spaces/invite/accept',
        'api/v1/spaces/members',
        'api/v1/spaces/members/remove',
        'api/v1/capture/projections'
    ) then
        raise exception 'SPC001_CONTROL_ROUTE_NOT_ALLOWED' using errcode='42501';
    end if;

    -- First-user-safe and idempotent. After SPC cutover this signature delegates
    -- to Space-owned bootstrap (112_user_bootstrap_cutover.sql).
    select * into v_boot
      from moneytrack.user_bootstrap_v1(
          p_telegram_user_id,p_username,p_first_name,p_telegram_language_code
      );
    v_actor:=v_boot.user_id;

    if v_method='GET' and v_path='api/v1/spaces' then
        return moneytrack.space_bootstrap_read_v1(v_actor);
    end if;

    if v_method='POST' and v_path='api/v1/spaces' then
        select jsonb_build_object('space_id',s.space_id,'name',s.name)
          into v_result
          from moneytrack.space_create_v1(v_actor,v_body->>'name') s;
        return v_result;
    end if;

    if v_method='PATCH' and v_path='api/v1/spaces' then
        v_space:=nullif(v_body->>'space_id','')::bigint;
        return jsonb_build_object(
            'space_id',v_space,
            'name',moneytrack.space_rename_v1(v_actor,v_space,v_body->>'name')
        );
    end if;

    if v_method='POST' and v_path='api/v1/spaces/archive' then
        v_space:=nullif(v_body->>'space_id','')::bigint;
        return jsonb_build_object(
            'space_id',v_space,
            'status',moneytrack.space_archive_v1(v_actor,v_space)
        );
    end if;

    if v_method='POST' and v_path='api/v1/spaces/active' then
        v_space:=nullif(v_body->>'space_id','')::bigint;
        return jsonb_build_object(
            'space_id',moneytrack.space_set_active_v1(v_actor,v_space)
        );
    end if;

    if v_method='POST' and v_path='api/v1/spaces/default-capture' then
        v_space:=nullif(v_body->>'space_id','')::bigint;
        return jsonb_build_object(
            'space_id',moneytrack.space_set_default_capture_v1(v_actor,v_space)
        );
    end if;

    if v_method='POST' and v_path='api/v1/spaces/invite' then
        v_space:=nullif(v_body->>'space_id','')::bigint;
        if p_invite_token_hash is null or p_invite_expires_at is null then
            raise exception 'INVITE_TOKEN_SERVER_INPUT_REQUIRED' using errcode='22023';
        end if;
        select jsonb_build_object(
            'invite_id',i.invite_id,
            'space_id',i.space_id,
            'expires_at',i.expires_at
        ) into v_result
        from moneytrack.space_invite_create_v1(
            v_actor,v_space,p_invite_token_hash,p_invite_expires_at
        ) i;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/spaces/invite/revoke' then
        v_invite:=nullif(v_body->>'invite_id','')::bigint;
        return jsonb_build_object(
            'invite_id',v_invite,
            'status',moneytrack.space_invite_revoke_v1(v_actor,v_invite)
        );
    end if;

    if v_method='POST' and v_path='api/v1/spaces/invite/accept' then
        if p_invite_token_hash is null then
            raise exception 'INVITE_TOKEN_SERVER_INPUT_REQUIRED' using errcode='22023';
        end if;
        select jsonb_build_object('space_id',a.space_id,'status',a.status)
          into v_result
          from moneytrack.space_invite_accept_v1(v_actor,p_invite_token_hash) a;
        return v_result;
    end if;

    if v_method='GET' and v_path='api/v1/spaces/members' then
        v_space:=nullif(v_query->>'space_id','')::bigint;
        return jsonb_build_object(
            'space_id',v_space,
            'members',moneytrack.space_members_api_read_v1(v_actor,v_space)
        );
    end if;

    if v_method='POST' and v_path='api/v1/spaces/members/remove' then
        v_space:=nullif(v_body->>'space_id','')::bigint;
        v_user:=nullif(v_body->>'user_id','')::bigint;
        return jsonb_build_object(
            'space_id',v_space,
            'user_id',v_user,
            'status',moneytrack.space_remove_member_v1(v_actor,v_space,v_user)
        );
    end if;

    if v_method='GET' and v_path='api/v1/capture/projections' then
        v_event:=nullif(v_query->>'capture_event_id','')::bigint;
        return jsonb_build_object(
            'capture_event_id',v_event,
            'projections',moneytrack.capture_accessible_projections_api_v1(v_actor,v_event)
        );
    end if;

    if v_method='POST' and v_path='api/v1/capture/projections' then
        v_event:=nullif(v_body->>'capture_event_id','')::bigint;
        return jsonb_build_object(
            'capture_event_id',v_event,
            'projections',moneytrack.capture_project_multi_api_v1(v_actor,v_event,v_body->'targets')
        );
    end if;

    raise exception 'SPC001_CONTROL_METHOD_NOT_ALLOWED: % %',v_method,v_path using errcode='42501';
end;
$function$;

comment on function moneytrack.spc001_control_api_dispatch_v1(bigint,text,text,text,text,text,jsonb,jsonb,text,timestamptz)
is 'SPC-001 lifecycle/capture dispatcher. Target Space authorization belongs to owner/member domain boundaries; opaque invite hash is the only invite credential persisted.';

commit;
