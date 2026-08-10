-- MoneyTrack — UX-022 — Account lifecycle domain boundary
-- All mutations are ownership-scoped and atomic. n8n must only adapt HTTP/auth.

begin;

create or replace function moneytrack.ux022_account_own_balance_original_v1(
    p_user_id bigint,
    p_account_id bigint,
    p_as_of timestamptz default now()
)
returns numeric
language sql
stable
as $function$
    with tx as (
        select coalesce(sum(
            case
                when t.transaction_type in ('openingbalance','income') then t.amount_original
                when t.transaction_type = 'expense' then -t.amount_original
                when t.transaction_type = 'adjustment' then t.amount_original
                else 0
            end
        ), 0) as amount
        from moneytrack.transactions t
        where t.user_id = p_user_id
          and t.account_id = p_account_id
          and t.transaction_date <= p_as_of
    ), tr as (
        select coalesce(sum(x.amount), 0) as amount
        from (
            select -t.from_amount as amount
            from moneytrack.transfers t
            where t.user_id = p_user_id
              and t.from_account_id = p_account_id
              and t.transfer_date <= p_as_of
            union all
            select t.to_amount as amount
            from moneytrack.transfers t
            where t.user_id = p_user_id
              and t.to_account_id = p_account_id
              and t.transfer_date <= p_as_of
        ) x
    )
    select tx.amount + tr.amount from tx cross join tr;
$function$;

create or replace function moneytrack.account_create_v1(
    p_telegram_user_id bigint,
    p_name text,
    p_account_type text,
    p_currency_code text,
    p_parent_id bigint default null,
    p_code text default null
)
returns table (account jsonb)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_name text := nullif(btrim(p_name), '');
    v_currency text := upper(nullif(btrim(p_currency_code), ''));
    v_type text := coalesce(nullif(btrim(p_account_type), ''), 'cash');
    v_code text := nullif(btrim(p_code), '');
    v_row moneytrack.accounts%rowtype;
begin
    if v_name is null then raise exception 'ACCOUNT_NAME_REQUIRED' using errcode = '22023'; end if;
    if v_currency is null or not exists (
        select 1 from moneytrack.currencies c
        where c.code = v_currency and coalesce(c.is_active, true) = true
    ) then raise exception 'ACCOUNT_CURRENCY_INVALID' using errcode = '22023'; end if;

    if p_parent_id is not null and not exists (
        select 1 from moneytrack.accounts a
        where a.id = p_parent_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true
    ) then raise exception 'TARGET_ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    if v_code is null then
        v_code := 'account_' || substr(md5(v_user_id::text || clock_timestamp()::text || random()::text), 1, 12);
    end if;

    insert into moneytrack.accounts(
        user_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id
    ) values (
        v_user_id, v_code, v_name, v_type, v_currency,
        true, now(), coalesce((select max(a.sort_order) + 10 from moneytrack.accounts a where a.user_id = v_user_id), 10), p_parent_id
    ) returning * into v_row;

    return query select jsonb_build_object(
        'id', v_row.id, 'code', v_row.code, 'name', v_row.name,
        'account_type', v_row.account_type, 'currency_code', v_row.currency_code,
        'parent_id', v_row.parent_id, 'sort_order', v_row.sort_order, 'is_active', v_row.is_active
    );
end;
$function$;

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
begin
    select * into v_source from moneytrack.accounts a
    where a.id = p_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true;
    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    insert into moneytrack.accounts(
        user_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id
    ) values (
        v_user_id,
        v_source.code || '_copy_' || substr(md5(clock_timestamp()::text || random()::text), 1, 6),
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

create or replace function moneytrack.account_edit_v1(
    p_telegram_user_id bigint,
    p_account_id bigint,
    p_name text,
    p_account_type text
)
returns table (account jsonb)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_name text := nullif(btrim(p_name), '');
    v_type text := nullif(btrim(p_account_type), '');
    v_row moneytrack.accounts%rowtype;
begin
    if v_name is null then raise exception 'ACCOUNT_NAME_REQUIRED' using errcode = '22023'; end if;

    update moneytrack.accounts a
       set name = v_name,
           account_type = coalesce(v_type, a.account_type)
     where a.id = p_account_id
       and a.user_id = v_user_id
       and coalesce(a.is_active, true) = true
     returning * into v_row;

    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    return query select jsonb_build_object(
        'id', v_row.id, 'code', v_row.code, 'name', v_row.name,
        'account_type', v_row.account_type, 'currency_code', v_row.currency_code,
        'parent_id', v_row.parent_id, 'sort_order', v_row.sort_order, 'is_active', v_row.is_active
    );
end;
$function$;

create or replace function moneytrack.account_move_v1(
    p_telegram_user_id bigint,
    p_account_id bigint,
    p_parent_id bigint
)
returns table (account_id bigint, previous_parent_id bigint, parent_id bigint, status text)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_previous_parent bigint;
begin
    select a.parent_id into v_previous_parent
    from moneytrack.accounts a
    where a.id = p_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true
    for update;
    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    if p_parent_id = p_account_id then raise exception 'ACCOUNT_HIERARCHY_CYCLE' using errcode = '22023'; end if;

    if p_parent_id is not null then
        if not exists (
            select 1 from moneytrack.accounts a
            where a.id = p_parent_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true
        ) then raise exception 'TARGET_ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

        if exists (
            with recursive descendants as (
                select a.id from moneytrack.accounts a
                where a.parent_id = p_account_id and a.user_id = v_user_id
                union all
                select child.id
                from moneytrack.accounts child
                join descendants d on child.parent_id = d.id
                where child.user_id = v_user_id
            )
            select 1 from descendants where id = p_parent_id
        ) then raise exception 'ACCOUNT_HIERARCHY_CYCLE' using errcode = '22023'; end if;
    end if;

    update moneytrack.accounts a set parent_id = p_parent_id
    where a.id = p_account_id and a.user_id = v_user_id;

    return query select p_account_id, v_previous_parent, p_parent_id, 'moved'::text;
end;
$function$;

create or replace function moneytrack.account_move_operations_preview_v1(
    p_telegram_user_id bigint,
    p_source_account_id bigint,
    p_target_account_id bigint
)
returns table (
    source_account_id bigint,
    target_account_id bigint,
    currency_code text,
    operation_count bigint,
    transfer_count bigint,
    collapsing_transfer_count bigint,
    opening_balance_conflict boolean
)
language plpgsql
stable
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_source_currency text;
    v_target_currency text;
begin
    if p_source_account_id = p_target_account_id then raise exception 'ACCOUNT_MOVE_TARGET_SAME' using errcode = '22023'; end if;

    select upper(a.currency_code) into v_source_currency from moneytrack.accounts a
    where a.id = p_source_account_id and a.user_id = v_user_id;
    if v_source_currency is null then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    select upper(a.currency_code) into v_target_currency from moneytrack.accounts a
    where a.id = p_target_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true;
    if v_target_currency is null then raise exception 'TARGET_ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;
    if v_source_currency <> v_target_currency then raise exception 'ACCOUNT_CURRENCY_INCOMPATIBLE' using errcode = '22023'; end if;

    return query
    select
        p_source_account_id,
        p_target_account_id,
        v_source_currency,
        (select count(*) from moneytrack.transactions t where t.user_id = v_user_id and t.account_id = p_source_account_id)::bigint,
        (select count(*) from moneytrack.transfers t where t.user_id = v_user_id and (t.from_account_id = p_source_account_id or t.to_account_id = p_source_account_id))::bigint,
        (select count(*) from moneytrack.transfers t where t.user_id = v_user_id and ((t.from_account_id = p_source_account_id and t.to_account_id = p_target_account_id) or (t.to_account_id = p_source_account_id and t.from_account_id = p_target_account_id)))::bigint,
        exists(
            select 1 from moneytrack.transactions s
            where s.user_id = v_user_id and s.account_id = p_source_account_id and s.transaction_type = 'openingbalance'
        ) and exists(
            select 1 from moneytrack.transactions d
            where d.user_id = v_user_id and d.account_id = p_target_account_id and d.transaction_type = 'openingbalance'
        );
end;
$function$;

create or replace function moneytrack.account_move_operations_v1(
    p_telegram_user_id bigint,
    p_source_account_id bigint,
    p_target_account_id bigint
)
returns table (operation_count bigint, transfer_count bigint, status text)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_source_currency text;
    v_target_currency text;
    v_operation_count bigint := 0;
    v_from_transfer_count bigint := 0;
    v_to_transfer_count bigint := 0;
begin
    if p_source_account_id = p_target_account_id then raise exception 'ACCOUNT_MOVE_TARGET_SAME' using errcode = '22023'; end if;

    perform pg_advisory_xact_lock(hashtextextended('UX022:account:' || least(p_source_account_id,p_target_account_id)::text, 0));
    perform pg_advisory_xact_lock(hashtextextended('UX022:account:' || greatest(p_source_account_id,p_target_account_id)::text, 0));

    select upper(a.currency_code) into v_source_currency from moneytrack.accounts a
    where a.id = p_source_account_id and a.user_id = v_user_id;
    if v_source_currency is null then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    select upper(a.currency_code) into v_target_currency from moneytrack.accounts a
    where a.id = p_target_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true;
    if v_target_currency is null then raise exception 'TARGET_ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;
    if v_source_currency <> v_target_currency then raise exception 'ACCOUNT_CURRENCY_INCOMPATIBLE' using errcode = '22023'; end if;

    if exists (
        select 1 from moneytrack.transfers t
        where t.user_id = v_user_id
          and ((t.from_account_id = p_source_account_id and t.to_account_id = p_target_account_id)
            or (t.to_account_id = p_source_account_id and t.from_account_id = p_target_account_id))
    ) then raise exception 'ACCOUNT_MOVE_WOULD_COLLAPSE_TRANSFER' using errcode = '22023'; end if;

    if exists (
        select 1 from moneytrack.transactions s
        where s.user_id = v_user_id and s.account_id = p_source_account_id and s.transaction_type = 'openingbalance'
    ) and exists (
        select 1 from moneytrack.transactions d
        where d.user_id = v_user_id and d.account_id = p_target_account_id and d.transaction_type = 'openingbalance'
    ) then raise exception 'ACCOUNT_MOVE_OPENING_BALANCE_CONFLICT' using errcode = '23505'; end if;

    update moneytrack.transactions t set account_id = p_target_account_id
    where t.user_id = v_user_id and t.account_id = p_source_account_id;
    get diagnostics v_operation_count = row_count;

    update moneytrack.transfers t set from_account_id = p_target_account_id
    where t.user_id = v_user_id and t.from_account_id = p_source_account_id;
    get diagnostics v_from_transfer_count = row_count;

    update moneytrack.transfers t set to_account_id = p_target_account_id
    where t.user_id = v_user_id and t.to_account_id = p_source_account_id;
    get diagnostics v_to_transfer_count = row_count;

    return query select v_operation_count, (v_from_transfer_count + v_to_transfer_count)::bigint, 'moved'::text;
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

    if exists (
        select 1 from moneytrack.user_default_accounts d where d.user_id = v_user_id and d.account_id = p_account_id
        union all
        select 1 from moneytrack.user_settings s where s.user_id = v_user_id and (s.default_expense_account_id = p_account_id or s.default_income_account_id = p_account_id)
    ) then raise exception 'DEFAULT_ACCOUNT_ARCHIVE_BLOCKED' using errcode = '22023'; end if;

    update moneytrack.accounts a set is_active = false where a.id = p_account_id and a.user_id = v_user_id;
    return query select p_account_id, 'archived'::text;
end;
$function$;

create or replace function moneytrack.account_restore_v1(
    p_telegram_user_id bigint,
    p_account_id bigint
)
returns table (account_id bigint, status text)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_parent_id bigint;
begin
    select a.parent_id into v_parent_id from moneytrack.accounts a
    where a.id = p_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = false
    for update;
    if not found then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    if v_parent_id is not null and not exists (
        select 1 from moneytrack.accounts p
        where p.id = v_parent_id and p.user_id = v_user_id and coalesce(p.is_active, true) = true
    ) then raise exception 'ACCOUNT_PARENT_ARCHIVED' using errcode = '22023'; end if;

    update moneytrack.accounts a set is_active = true where a.id = p_account_id and a.user_id = v_user_id;
    return query select p_account_id, 'restored'::text;
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

    if exists (select 1 from moneytrack.accounts c where c.user_id = v_user_id and c.parent_id = p_account_id) then
        raise exception 'ACCOUNT_HAS_CHILDREN' using errcode = '22023';
    end if;

    if exists (select 1 from moneytrack.transactions t where t.user_id = v_user_id and t.account_id = p_account_id) then
        raise exception 'ACCOUNT_HAS_OPERATIONS' using errcode = '22023';
    end if;

    if exists (select 1 from moneytrack.transfers t where t.user_id = v_user_id and (t.from_account_id = p_account_id or t.to_account_id = p_account_id)) then
        raise exception 'ACCOUNT_HAS_REFERENCES' using errcode = '22023';
    end if;

    if exists (
        select 1 from moneytrack.user_default_accounts d where d.user_id = v_user_id and d.account_id = p_account_id
        union all
        select 1 from moneytrack.user_settings s where s.user_id = v_user_id and (s.default_expense_account_id = p_account_id or s.default_income_account_id = p_account_id)
    ) then raise exception 'ACCOUNT_HAS_REFERENCES' using errcode = '22023'; end if;

    v_balance := moneytrack.ux022_account_own_balance_original_v1(v_user_id, p_account_id, now());
    if abs(coalesce(v_balance, 0)) > 0.005 then raise exception 'ACCOUNT_BALANCE_NOT_ZERO' using errcode = '22023'; end if;

    delete from moneytrack.accounts a where a.id = p_account_id and a.user_id = v_user_id;
    return query select p_account_id, 'deleted'::text;
end;
$function$;

create or replace function moneytrack.accounts_archived_read_v1(p_telegram_user_id bigint)
returns table (accounts jsonb)
language sql
stable
as $function$
    with user_ctx as (
        select moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id) as user_id
    )
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', a.id, 'code', a.code, 'name', a.name,
            'account_type', a.account_type, 'currency_code', a.currency_code,
            'parent_id', a.parent_id, 'sort_order', a.sort_order, 'is_active', a.is_active
        ) order by a.name, a.id
    ), '[]'::jsonb)
    from user_ctx u
    join moneytrack.accounts a on a.user_id = u.user_id
    where coalesce(a.is_active, true) = false;
$function$;

comment on function moneytrack.account_move_operations_v1(bigint,bigint,bigint)
is 'UX-022 atomic history ownership reassignment. Preserves transaction/transfer financial fields, blocks currency mismatch, opening-balance collision and transfer collapse.';
comment on function moneytrack.account_delete_v1(bigint,bigint)
is 'UX-022 hard-delete safety boundary. Requires zero balance, zero history/references and zero children; never cascade-deletes finance history.';

commit;
