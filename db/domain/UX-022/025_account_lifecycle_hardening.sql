-- UX-022 account lifecycle hardening overlays.
-- Kept separate from the primary lifecycle migration so each correction remains
-- reviewable and can be validated independently against the current schema.

begin;

create or replace function moneytrack.account_copy_v1(
    p_telegram_user_id bigint,
    p_account_id bigint
)
returns table (account jsonb)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_source moneytrack.accounts%rowtype;
    v_row moneytrack.accounts%rowtype;
    v_code text;
begin
    select * into v_source
    from moneytrack.accounts a
    where a.id = p_account_id
      and a.user_id = v_user_id
      and coalesce(a.is_active, true) = true;
    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    -- Do not append to an arbitrary legacy code: its column may have a tight
    -- length constraint. Generate a fresh compact code exactly as account_create.
    v_code := 'account_' || substr(
        md5(v_user_id::text || ':' || p_account_id::text || ':' || clock_timestamp()::text || ':' || random()::text),
        1,
        12
    );

    insert into moneytrack.accounts(
        user_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id
    ) values (
        v_user_id,
        v_code,
        v_source.name || ' — копия',
        v_source.account_type,
        v_source.currency_code,
        true,
        now(),
        coalesce(v_source.sort_order, 0) + 1,
        v_source.parent_id
    ) returning * into v_row;

    return query select jsonb_build_object(
        'id', v_row.id, 'code', v_row.code, 'name', v_row.name,
        'account_type', v_row.account_type, 'currency_code', v_row.currency_code,
        'parent_id', v_row.parent_id, 'sort_order', v_row.sort_order, 'is_active', v_row.is_active
    );
end;
$function$;

commit;
