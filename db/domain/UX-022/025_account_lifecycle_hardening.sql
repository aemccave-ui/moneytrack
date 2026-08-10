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

-- Default-account storage evolved independently from UX-022. Do not compile the
-- lifecycle boundary against optional legacy columns. user_settings is inspected
-- through JSON so any account-looking field is guarded without a hard column
-- dependency; the optional legacy relation is queried dynamically only when its
-- canonical (user_id, account_id) shape is actually present.
create or replace function moneytrack.ux022_account_is_default_v1(
    p_user_id bigint,
    p_account_id bigint
)
returns boolean
language plpgsql
stable
as $function$
declare
    v_result boolean := false;
begin
    select exists (
        select 1
        from moneytrack.user_settings s
        cross join lateral jsonb_each_text(to_jsonb(s)) kv
        where s.user_id = p_user_id
          and (
              kv.key = 'setdefaultaccount'
              or kv.key like '%account_id%'
              or lower(kv.key) like '%accountid%'
          )
          and kv.value ~ '^[0-9]+$'
          and kv.value::bigint = p_account_id
    ) into v_result;

    if v_result then
        return true;
    end if;

    if to_regclass('moneytrack.user_default_accounts') is not null then
        if not exists (
            select 1
            from information_schema.columns c
            where c.table_schema = 'moneytrack'
              and c.table_name = 'user_default_accounts'
              and c.column_name = 'user_id'
        ) or not exists (
            select 1
            from information_schema.columns c
            where c.table_schema = 'moneytrack'
              and c.table_name = 'user_default_accounts'
              and c.column_name = 'account_id'
        ) then
            raise exception 'UX022_DEFAULT_ACCOUNT_REFERENCE_SHAPE_UNKNOWN'
                using errcode = '55000';
        end if;

        execute 'select exists (
            select 1 from moneytrack.user_default_accounts
            where user_id = $1 and account_id = $2
        )'
        into v_result
        using p_user_id, p_account_id;
    end if;

    return coalesce(v_result, false);
end;
$function$;

create or replace function moneytrack.account_archive_v1(
    p_telegram_user_id bigint,
    p_account_id bigint
)
returns table (account_id bigint, status text)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_balance numeric;
begin
    perform 1 from moneytrack.accounts a
    where a.id = p_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true
    for update;
    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    if exists (
        select 1 from moneytrack.accounts child
        where child.user_id = v_user_id and child.parent_id = p_account_id and coalesce(child.is_active, true) = true
    ) then raise exception 'ACCOUNT_HAS_CHILDREN' using errcode = '22023'; end if;

    v_balance := moneytrack.ux022_account_own_balance_original_v1(v_user_id, p_account_id, now());
    if abs(coalesce(v_balance, 0)) > 0.005 then raise exception 'ACCOUNT_BALANCE_NOT_ZERO' using errcode = '22023'; end if;

    if moneytrack.ux022_account_is_default_v1(v_user_id, p_account_id) then
        raise exception 'DEFAULT_ACCOUNT_ARCHIVE_BLOCKED' using errcode = '22023';
    end if;

    update moneytrack.accounts a set is_active = false
    where a.id = p_account_id and a.user_id = v_user_id;

    return query select p_account_id, 'archived'::text;
end;
$function$;

create or replace function moneytrack.account_delete_v1(
    p_telegram_user_id bigint,
    p_account_id bigint
)
returns table (deleted_id bigint, status text)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_balance numeric;
begin
    perform 1 from moneytrack.accounts a
    where a.id = p_account_id and a.user_id = v_user_id
    for update;
    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    if exists (
        select 1 from moneytrack.accounts c
        where c.user_id = v_user_id and c.parent_id = p_account_id
    ) then raise exception 'ACCOUNT_HAS_CHILDREN' using errcode = '22023'; end if;

    if exists (
        select 1 from moneytrack.transactions t
        where t.user_id = v_user_id and t.account_id = p_account_id
    ) then raise exception 'ACCOUNT_HAS_OPERATIONS' using errcode = '22023'; end if;

    if exists (
        select 1 from moneytrack.transfers t
        where t.user_id = v_user_id
          and (t.from_account_id = p_account_id or t.to_account_id = p_account_id)
    ) then raise exception 'ACCOUNT_HAS_REFERENCES' using errcode = '22023'; end if;

    if moneytrack.ux022_account_is_default_v1(v_user_id, p_account_id) then
        raise exception 'ACCOUNT_HAS_REFERENCES' using errcode = '22023';
    end if;

    v_balance := moneytrack.ux022_account_own_balance_original_v1(v_user_id, p_account_id, now());
    if abs(coalesce(v_balance, 0)) > 0.005 then raise exception 'ACCOUNT_BALANCE_NOT_ZERO' using errcode = '22023'; end if;

    delete from moneytrack.accounts a
    where a.id = p_account_id and a.user_id = v_user_id;

    return query select p_account_id, 'deleted'::text;
end;
$function$;

comment on function moneytrack.ux022_account_is_default_v1(bigint,bigint)
is 'UX-022 schema-tolerant default-account reference guard. Avoids hard dependencies on optional legacy default-account columns/tables.';

commit;
