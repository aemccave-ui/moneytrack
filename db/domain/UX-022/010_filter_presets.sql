-- MoneyTrack — UX-022 — immutable account/category filter presets
-- n8n is transport/auth only. Preset persistence and ownership live here.

begin;

create table if not exists moneytrack.filter_presets (
    id bigserial primary key,
    user_id bigint not null references moneytrack.app_users(id) on delete cascade,
    name text not null,
    account_ids bigint[] not null default '{}'::bigint[],
    income_category_ids bigint[] not null default '{}'::bigint[],
    expense_category_ids bigint[] not null default '{}'::bigint[],
    created_at timestamptz not null default now(),
    constraint filter_presets_name_nonblank check (btrim(name) <> ''),
    constraint filter_presets_name_length check (char_length(name) <= 80)
);

-- UX-022 existed before the production-hardening baseline. If that earlier table
-- is already present, CREATE TABLE IF NOT EXISTS alone would silently preserve a
-- partial legacy shape. Add the immutable payload columns idempotently and then
-- validate the canonical types before any function is installed.
alter table moneytrack.filter_presets
    add column if not exists account_ids bigint[] default '{}'::bigint[];
alter table moneytrack.filter_presets
    add column if not exists income_category_ids bigint[] default '{}'::bigint[];
alter table moneytrack.filter_presets
    add column if not exists expense_category_ids bigint[] default '{}'::bigint[];
alter table moneytrack.filter_presets
    add column if not exists created_at timestamptz default now();

update moneytrack.filter_presets
   set account_ids = coalesce(account_ids, '{}'::bigint[]),
       income_category_ids = coalesce(income_category_ids, '{}'::bigint[]),
       expense_category_ids = coalesce(expense_category_ids, '{}'::bigint[]),
       created_at = coalesce(created_at, now())
 where account_ids is null
    or income_category_ids is null
    or expense_category_ids is null
    or created_at is null;

alter table moneytrack.filter_presets alter column account_ids set default '{}'::bigint[];
alter table moneytrack.filter_presets alter column account_ids set not null;
alter table moneytrack.filter_presets alter column income_category_ids set default '{}'::bigint[];
alter table moneytrack.filter_presets alter column income_category_ids set not null;
alter table moneytrack.filter_presets alter column expense_category_ids set default '{}'::bigint[];
alter table moneytrack.filter_presets alter column expense_category_ids set not null;
alter table moneytrack.filter_presets alter column created_at set default now();
alter table moneytrack.filter_presets alter column created_at set not null;

do $preset_shape$
declare
    v_bad text[] := '{}'::text[];
begin
    if to_regclass('moneytrack.filter_presets') is null then
        raise exception 'UX022_FILTER_PRESETS_TABLE_MISSING';
    end if;

    if not exists (
        select 1 from information_schema.columns
        where table_schema='moneytrack' and table_name='filter_presets'
          and column_name='id' and data_type='bigint'
    ) then v_bad := array_append(v_bad, 'id'); end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema='moneytrack' and table_name='filter_presets'
          and column_name='user_id' and data_type='bigint'
    ) then v_bad := array_append(v_bad, 'user_id'); end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema='moneytrack' and table_name='filter_presets'
          and column_name='name' and data_type='text'
    ) then v_bad := array_append(v_bad, 'name'); end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema='moneytrack' and table_name='filter_presets'
          and column_name='account_ids' and udt_name='_int8'
    ) then v_bad := array_append(v_bad, 'account_ids'); end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema='moneytrack' and table_name='filter_presets'
          and column_name='income_category_ids' and udt_name='_int8'
    ) then v_bad := array_append(v_bad, 'income_category_ids'); end if;
    if not exists (
        select 1 from information_schema.columns
        where table_schema='moneytrack' and table_name='filter_presets'
          and column_name='expense_category_ids' and udt_name='_int8'
    ) then v_bad := array_append(v_bad, 'expense_category_ids'); end if;

    if cardinality(v_bad) > 0 then
        raise exception 'UX022_FILTER_PRESETS_LEGACY_SHAPE_INCOMPATIBLE: %', array_to_string(v_bad, ',');
    end if;
end;
$preset_shape$;

create index if not exists ix_filter_presets_user_created
    on moneytrack.filter_presets(user_id, created_at, id);

create or replace function moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id bigint)
returns bigint
language plpgsql
stable
as $function$
declare
    v_user_id bigint;
begin
    if p_telegram_user_id is null then
        raise exception 'TELEGRAM_USER_ID_REQUIRED' using errcode = '22023';
    end if;

    select u.id into v_user_id
    from moneytrack.app_users u
    where u.telegram_user_id = p_telegram_user_id
    limit 1;

    if v_user_id is null then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    return v_user_id;
end;
$function$;

create or replace function moneytrack.filter_presets_read_v1(p_telegram_user_id bigint)
returns table (presets jsonb)
language sql
stable
as $function$
    with user_ctx as (
        select moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id) as user_id
    )
    select coalesce(
        jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'name', p.name,
                'account_ids', p.account_ids,
                'income_category_ids', p.income_category_ids,
                'expense_category_ids', p.expense_category_ids,
                'created_at', p.created_at
            ) order by p.created_at, p.id
        ) filter (where p.id is not null),
        '[]'::jsonb
    )
    from user_ctx u
    left join moneytrack.filter_presets p on p.user_id = u.user_id;
$function$;

create or replace function moneytrack.filter_preset_create_v1(
    p_telegram_user_id bigint,
    p_name text,
    p_account_ids bigint[],
    p_income_category_ids bigint[],
    p_expense_category_ids bigint[]
)
returns table (preset jsonb)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_name text := nullif(btrim(p_name), '');
    v_account_ids bigint[] := coalesce(p_account_ids, '{}'::bigint[]);
    v_income_ids bigint[] := coalesce(p_income_category_ids, '{}'::bigint[]);
    v_expense_ids bigint[] := coalesce(p_expense_category_ids, '{}'::bigint[]);
    v_row moneytrack.filter_presets%rowtype;
begin
    v_user_id := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);

    if v_name is null or char_length(v_name) > 80 then
        raise exception 'PRESET_NAME_INVALID' using errcode = '22023';
    end if;

    if exists (
        select 1 from unnest(v_account_ids) requested(id)
        where not exists (
            select 1 from moneytrack.accounts a
            where a.id = requested.id
              and a.user_id = v_user_id
              and coalesce(a.is_active, true) = true
        )
    ) then
        raise exception 'ACCOUNT_IDS_INVALID' using errcode = '22023';
    end if;

    if exists (
        select 1 from unnest(v_income_ids || v_expense_ids) requested(id)
        where not exists (
            select 1 from moneytrack.category_catalog c
            where c.id = requested.id
              and coalesce(c.is_active, true) = true
              and c.user_id in (0, v_user_id)
        )
    ) then
        raise exception 'CATEGORY_IDS_INVALID' using errcode = '22023';
    end if;

    select array_agg(distinct id order by id) into v_account_ids from unnest(v_account_ids) x(id);
    select array_agg(distinct id order by id) into v_income_ids from unnest(v_income_ids) x(id);
    select array_agg(distinct id order by id) into v_expense_ids from unnest(v_expense_ids) x(id);
    v_account_ids := coalesce(v_account_ids, '{}'::bigint[]);
    v_income_ids := coalesce(v_income_ids, '{}'::bigint[]);
    v_expense_ids := coalesce(v_expense_ids, '{}'::bigint[]);

    insert into moneytrack.filter_presets(
        user_id, name, account_ids, income_category_ids, expense_category_ids
    ) values (
        v_user_id, v_name, v_account_ids, v_income_ids, v_expense_ids
    ) returning * into v_row;

    return query select jsonb_build_object(
        'id', v_row.id,
        'name', v_row.name,
        'account_ids', v_row.account_ids,
        'income_category_ids', v_row.income_category_ids,
        'expense_category_ids', v_row.expense_category_ids,
        'created_at', v_row.created_at
    );
end;
$function$;

create or replace function moneytrack.filter_preset_rename_v1(
    p_telegram_user_id bigint,
    p_preset_id bigint,
    p_name text
)
returns table (preset jsonb)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_name text := nullif(btrim(p_name), '');
    v_row moneytrack.filter_presets%rowtype;
begin
    v_user_id := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    if p_preset_id is null then raise exception 'PRESET_ID_INVALID' using errcode = '22023'; end if;
    if v_name is null or char_length(v_name) > 80 then raise exception 'PRESET_NAME_INVALID' using errcode = '22023'; end if;

    update moneytrack.filter_presets p
       set name = v_name
     where p.id = p_preset_id
       and p.user_id = v_user_id
     returning * into v_row;

    if not found then raise exception 'PRESET_NOT_FOUND' using errcode = 'P0002'; end if;

    return query select jsonb_build_object(
        'id', v_row.id,
        'name', v_row.name,
        'account_ids', v_row.account_ids,
        'income_category_ids', v_row.income_category_ids,
        'expense_category_ids', v_row.expense_category_ids,
        'created_at', v_row.created_at
    );
end;
$function$;

create or replace function moneytrack.filter_preset_delete_v1(
    p_telegram_user_id bigint,
    p_preset_id bigint
)
returns table (deleted_id bigint)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_deleted_id bigint;
begin
    v_user_id := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    if p_preset_id is null then raise exception 'PRESET_ID_INVALID' using errcode = '22023'; end if;

    delete from moneytrack.filter_presets p
    where p.id = p_preset_id and p.user_id = v_user_id
    returning p.id into v_deleted_id;

    if v_deleted_id is null then raise exception 'PRESET_NOT_FOUND' using errcode = 'P0002'; end if;
    return query select v_deleted_id;
end;
$function$;

comment on function moneytrack.filter_preset_create_v1(bigint,text,bigint[],bigint[],bigint[])
is 'UX-022 immutable preset creation boundary. Payload contains account/category IDs only; period is deliberately absent.';
comment on function moneytrack.filter_preset_rename_v1(bigint,bigint,text)
is 'UX-022 rename-only preset mutation boundary.';

commit;
