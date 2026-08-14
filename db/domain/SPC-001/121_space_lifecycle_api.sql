-- MoneyTrack SPC-001 — lifecycle/capture JSON API wrappers for thin n8n adapters.

begin;

create or replace function moneytrack.space_bootstrap_read_v1(p_actor_user_id bigint)
returns jsonb
language plpgsql
stable
as $function$
declare v_result jsonb;
begin
    if p_actor_user_id is null then raise exception 'ACTOR_REQUIRED' using errcode='22023'; end if;
    select jsonb_build_object(
      'spaces',coalesce((select jsonb_agg(to_jsonb(s) order by s.is_owner desc,s.space_id) from moneytrack.space_list_v1(p_actor_user_id) s),'[]'::jsonb),
      'current_space_id',us.current_workspace_id,
      'default_capture_space_id',us.default_capture_space_id
    ) into v_result
    from moneytrack.user_settings us
    where us.user_id=p_actor_user_id;
    if v_result is null then raise exception 'USER_SETTINGS_NOT_FOUND' using errcode='P0002'; end if;
    return v_result;
end;
$function$;

create or replace function moneytrack.space_members_api_read_v1(p_actor_user_id bigint,p_space_id bigint)
returns jsonb
language plpgsql
stable
as $function$
declare v_result jsonb;
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);
    select coalesce(jsonb_agg(to_jsonb(m) order by (m.role='owner') desc,m.joined_at,m.user_id),'[]'::jsonb)
      into v_result from moneytrack.space_member_list_v1(p_actor_user_id,p_space_id) m;
    return v_result;
end;
$function$;

create or replace function moneytrack.capture_accessible_projections_api_v1(p_actor_user_id bigint,p_capture_event_id bigint)
returns jsonb
language plpgsql
stable
as $function$
declare v_result jsonb;
begin
    select coalesce(jsonb_agg(to_jsonb(p) order by p.transaction_id),'[]'::jsonb)
      into v_result
      from moneytrack.capture_accessible_projections_v1(p_actor_user_id,p_capture_event_id) p;
    return v_result;
end;
$function$;

create or replace function moneytrack.capture_project_multi_api_v1(p_actor_user_id bigint,p_capture_event_id bigint,p_targets jsonb)
returns jsonb
language plpgsql
volatile
as $function$
declare v_result jsonb;
begin
    select coalesce(jsonb_agg(to_jsonb(p) order by p.transaction_id),'[]'::jsonb)
      into v_result
      from moneytrack.capture_project_multi_v1(p_actor_user_id,p_capture_event_id,p_targets) p;
    return v_result;
end;
$function$;

comment on function moneytrack.space_bootstrap_read_v1(bigint)
is 'SPC-001 protected MiniApp Space discovery. Returns only active memberships plus user preference pointers; contains no finance values.';
comment on function moneytrack.capture_accessible_projections_api_v1(bigint,bigint)
is 'SPC-001 privacy-preserving linkage wrapper. Hidden projection count and inaccessible Space metadata are never returned.';

commit;
