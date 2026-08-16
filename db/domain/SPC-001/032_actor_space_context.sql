-- MoneyTrack SPC-001 — Telegram identity to Space actor context.

begin;

create or replace function moneytrack.spc001_resolve_actor_user_id_v1(
    p_telegram_user_id bigint
)
returns bigint
language plpgsql
stable
as $function$
declare v_actor bigint;
begin
    if p_telegram_user_id is null then
        raise exception 'TELEGRAM_USER_ID_REQUIRED' using errcode='22023';
    end if;
    select u.id into v_actor
      from moneytrack.app_users u
     where u.telegram_user_id=p_telegram_user_id
     limit 1;
    if v_actor is null then
        raise exception 'USER_NOT_FOUND' using errcode='P0002';
    end if;
    return v_actor;
end;
$function$;

create or replace function moneytrack.spc001_resolve_actor_space_v1(
    p_telegram_user_id bigint,
    p_space_id bigint
)
returns table(actor_user_id bigint,space_id bigint)
language plpgsql
stable
as $function$
declare v_actor bigint;
begin
    v_actor:=moneytrack.spc001_resolve_actor_user_id_v1(p_telegram_user_id);
    perform moneytrack.assert_space_member_v1(v_actor,p_space_id);
    return query select v_actor,p_space_id;
end;
$function$;

comment on function moneytrack.spc001_resolve_actor_space_v1(bigint,bigint)
is 'SPC-001 server context. Telegram identity resolves actor; client Space id remains untrusted until active membership succeeds.';

commit;
