-- MoneyTrack SPC-001F4 — owner-only member display identity enrichment.
-- Additive read-model patch. No tenancy, membership or financial ownership
-- semantics change. Telegram numeric identity is deliberately not exposed.

begin;

create or replace function moneytrack.space_members_api_read_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns jsonb
language plpgsql
stable
as $function$
declare
    v_result jsonb;
begin
    perform moneytrack.assert_space_owner_v1(p_actor_user_id,p_space_id);

    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'user_id',m.user_id,
                'role',m.role,
                'joined_at',m.joined_at,
                'is_active',m.is_active,
                'first_name',nullif(btrim(u.first_name),''),
                'username',nullif(btrim(u.username),'')
            )
            order by (m.role='owner') desc,m.joined_at,m.user_id
        ),
        '[]'::jsonb
    )
      into v_result
      from moneytrack.space_member_list_v1(p_actor_user_id,p_space_id) m
      left join moneytrack.app_users u on u.id=m.user_id;

    return v_result;
end;
$function$;

comment on function moneytrack.space_members_api_read_v1(bigint,bigint)
is 'SPC-001 owner-only member read model. Returns display identity (first_name/username) without Telegram numeric identity; authorization remains assert_space_owner_v1.';

commit;
