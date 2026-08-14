-- MoneyTrack — SPC-001B — Space lifecycle hardening
-- Apply after 110_space_lifecycle.sql.
--
-- Active/default Space pointers are guarded by active membership. Therefore an
-- archive must clear every pointer to the target Space atomically BEFORE the
-- workspace becomes inactive; otherwise the pointer trigger could fail while a
-- second pointer still references the just-archived Space.

begin;

create or replace function moneytrack.space_archive_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns text
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);

    update moneytrack.user_settings
       set current_workspace_id = case
               when current_workspace_id=p_space_id then null
               else current_workspace_id
           end,
           default_capture_space_id = case
               when default_capture_space_id=p_space_id then null
               else default_capture_space_id
           end,
           updated_at=now()
     where current_workspace_id=p_space_id
        or default_capture_space_id=p_space_id;

    update moneytrack.workspaces
       set is_active=false,
           archived_at=now(),
           updated_at=now()
     where id=p_space_id
       and coalesce(is_active,true)=true;

    if not found then
        raise exception 'SPACE_NOT_FOUND_OR_INACTIVE' using errcode='P0002';
    end if;

    return 'archived';
end;
$function$;

comment on function moneytrack.space_archive_v1(bigint,bigint)
is 'SPC-001 owner-only archive. Clears active/default pointers atomically before deactivating the Space so pointer-membership guards cannot deadlock archive.';

commit;
