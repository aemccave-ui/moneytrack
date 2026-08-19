-- MoneyTrack — UX-025B — Space-owned mutable category directory
--
-- SOURCE ONLY until an explicit UX-025 backend/runtime gate authorizes apply.
-- category_catalog.space_id is the tenancy boundary inherited from SPC-001.
-- user_id remains compatibility/actor provenance and MUST NOT authorize access.

begin;

-- ---------------------------------------------------------------------------
-- Canonical read model for Settings category management.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.category_directory_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns table(categories jsonb)
language plpgsql
stable
as $function$
declare
    v_language text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    select coalesce(us.language_code, u.language_code, 'en')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id = u.id
     where u.id = p_actor_user_id;

    return query
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'id', c.id,
            'space_id', c.space_id,
            'code', c.code,
            'name', coalesce(tr.name, c.code),
            'flow_type', c.flow_type,
            'parent_id', c.parent_id,
            'sort_order', coalesce(c.sort_order, 0),
            'is_active', coalesce(c.is_active, true),
            'editable', true
        )
        order by coalesce(c.sort_order, 0), c.id
    ), '[]'::jsonb)
    from moneytrack.category_catalog c
    left join moneytrack.category_catalog_translations tr
      on tr.category_id = c.id
     and tr.language_code = v_language
    where c.space_id = p_space_id
      and coalesce(c.is_active, true) = true;
end;
$function$;

comment on function moneytrack.category_directory_space_v1(bigint,bigint)
is 'UX-025 Settings category directory. Active membership is required and only active categories in the selected Space are returned.';

-- ---------------------------------------------------------------------------
-- Create.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.category_create_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_name text,
    p_flow_type text,
    p_parent_id bigint default null,
    p_sort_order integer default null
)
returns table(category jsonb)
language plpgsql
volatile
as $function$
declare
    v_language text;
    v_name text := nullif(btrim(p_name), '');
    v_flow text := lower(nullif(btrim(p_flow_type), ''));
    v_code text;
    v_sort integer;
    v_id bigint;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if v_name is null then
        raise exception 'CATEGORY_NAME_REQUIRED' using errcode = '22023';
    end if;
    if v_flow is null or v_flow not in ('income', 'expense') then
        raise exception 'CATEGORY_FLOW_TYPE_INVALID' using errcode = '22023';
    end if;

    if p_parent_id is not null and not exists (
        select 1
        from moneytrack.category_catalog p
        where p.id = p_parent_id
          and p.space_id = p_space_id
          and coalesce(p.is_active, true) = true
    ) then
        raise exception 'CATEGORY_PARENT_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('UX-025:category-create:' || p_space_id::text, 0)
    );

    select coalesce(
        p_sort_order,
        coalesce(max(c.sort_order), 0) + 10
    )::integer
      into v_sort
      from moneytrack.category_catalog c
     where c.space_id = p_space_id
       and c.parent_id is not distinct from p_parent_id
       and coalesce(c.is_active, true) = true;

    -- Stable uniqueness is supplied by the accepted SPC-001 (space_id, code)
    -- unique index. Human names remain localized display values and therefore
    -- are intentionally not used as a database key.
    v_code := 'category_' || substr(
        md5(p_space_id::text || ':' || p_actor_user_id::text || ':' || clock_timestamp()::text || ':' || random()::text),
        1,
        20
    );

    insert into moneytrack.category_catalog(
        user_id,
        space_id,
        code,
        parent_id,
        is_active,
        sort_order,
        created_at,
        flow_type,
        created_by_user_id,
        updated_by_user_id
    ) values (
        p_actor_user_id,
        p_space_id,
        v_code,
        p_parent_id,
        true,
        v_sort,
        now(),
        v_flow,
        p_actor_user_id,
        p_actor_user_id
    )
    returning id into v_id;

    select coalesce(us.language_code, u.language_code, 'en')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id = u.id
     where u.id = p_actor_user_id;

    insert into moneytrack.category_catalog_translations(category_id, language_code, name)
    values (v_id, v_language, v_name)
    on conflict (category_id, language_code)
    do update set name = excluded.name;

    return query
    select jsonb_build_object(
        'id', c.id,
        'space_id', c.space_id,
        'code', c.code,
        'name', v_name,
        'flow_type', c.flow_type,
        'parent_id', c.parent_id,
        'sort_order', c.sort_order,
        'is_active', c.is_active,
        'editable', true
    )
    from moneytrack.category_catalog c
    where c.id = v_id;
end;
$function$;

comment on function moneytrack.category_create_space_v1(bigint,bigint,text,text,bigint,integer)
is 'UX-025 category create. Creates one active Space-local category; user_id is compatibility/provenance only.';

-- ---------------------------------------------------------------------------
-- Edit + reparent. Full state is supplied so NULL parent means root rather
-- than an ambiguous omitted field.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.category_edit_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_category_id bigint,
    p_name text,
    p_flow_type text,
    p_parent_id bigint,
    p_sort_order integer
)
returns table(category jsonb)
language plpgsql
volatile
as $function$
declare
    v_language text;
    v_name text := nullif(btrim(p_name), '');
    v_flow text := lower(nullif(btrim(p_flow_type), ''));
    v_row moneytrack.category_catalog%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if v_name is null then
        raise exception 'CATEGORY_NAME_REQUIRED' using errcode = '22023';
    end if;
    if v_flow is null or v_flow not in ('income', 'expense') then
        raise exception 'CATEGORY_FLOW_TYPE_INVALID' using errcode = '22023';
    end if;
    if p_sort_order is null then
        raise exception 'CATEGORY_SORT_ORDER_REQUIRED' using errcode = '22023';
    end if;
    if p_parent_id = p_category_id then
        raise exception 'CATEGORY_PARENT_CYCLE' using errcode = '22023';
    end if;

    select *
      into v_row
      from moneytrack.category_catalog c
     where c.id = p_category_id
       and c.space_id = p_space_id
       and coalesce(c.is_active, true) = true
     for update;

    if not found then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;

    if p_parent_id is not null and not exists (
        select 1
        from moneytrack.category_catalog p
        where p.id = p_parent_id
          and p.space_id = p_space_id
          and coalesce(p.is_active, true) = true
    ) then
        raise exception 'CATEGORY_PARENT_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;

    if p_parent_id is not null and exists (
        with recursive descendants(id) as (
            select c.id
            from moneytrack.category_catalog c
            where c.parent_id = p_category_id
              and c.space_id = p_space_id
              and coalesce(c.is_active, true) = true
            union all
            select c.id
            from moneytrack.category_catalog c
            join descendants d on c.parent_id = d.id
            where c.space_id = p_space_id
              and coalesce(c.is_active, true) = true
        )
        select 1 from descendants where id = p_parent_id
    ) then
        raise exception 'CATEGORY_PARENT_CYCLE' using errcode = '22023';
    end if;

    update moneytrack.category_catalog c
       set parent_id = p_parent_id,
           sort_order = p_sort_order,
           flow_type = v_flow,
           updated_by_user_id = p_actor_user_id
     where c.id = p_category_id
       and c.space_id = p_space_id
     returning * into v_row;

    select coalesce(us.language_code, u.language_code, 'en')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id = u.id
     where u.id = p_actor_user_id;

    insert into moneytrack.category_catalog_translations(category_id, language_code, name)
    values (v_row.id, v_language, v_name)
    on conflict (category_id, language_code)
    do update set name = excluded.name;

    return query
    select jsonb_build_object(
        'id', v_row.id,
        'space_id', v_row.space_id,
        'code', v_row.code,
        'name', v_name,
        'flow_type', v_row.flow_type,
        'parent_id', v_row.parent_id,
        'sort_order', v_row.sort_order,
        'is_active', v_row.is_active,
        'editable', true
    );
end;
$function$;

comment on function moneytrack.category_edit_space_v1(bigint,bigint,bigint,text,text,bigint,integer)
is 'UX-025 category edit/reparent. Same-Space parent and recursive cycle guards are authoritative in PostgreSQL.';

-- ---------------------------------------------------------------------------
-- Preliminary numeric reorder primitive. UX-025/015 replaces this overload
-- with the accepted atomic sibling up/down contract before transport apply.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.category_reorder_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_category_id bigint,
    p_sort_order integer
)
returns table(category_id bigint, sort_order integer, status text)
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if p_sort_order is null then
        raise exception 'CATEGORY_SORT_ORDER_REQUIRED' using errcode = '22023';
    end if;

    return query
    update moneytrack.category_catalog c
       set sort_order = p_sort_order,
           updated_by_user_id = p_actor_user_id
     where c.id = p_category_id
       and c.space_id = p_space_id
       and coalesce(c.is_active, true) = true
    returning c.id, c.sort_order, 'reordered'::text;

    if not found then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;
end;
$function$;

comment on function moneytrack.category_reorder_space_v1(bigint,bigint,bigint,integer)
is 'UX-025 preliminary Space-local numeric reorder primitive; replaced by 015 atomic sibling reorder.';

-- ---------------------------------------------------------------------------
-- Delete semantics = archive. Never physically remove historical category ids.
-- Active children must be explicitly moved/archived first.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.category_delete_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_category_id bigint
)
returns table(category_id bigint, status text)
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if not exists (
        select 1
        from moneytrack.category_catalog c
        where c.id = p_category_id
          and c.space_id = p_space_id
          and coalesce(c.is_active, true) = true
    ) then
        raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode = 'P0002';
    end if;

    if exists (
        select 1
        from moneytrack.category_catalog child
        where child.parent_id = p_category_id
          and child.space_id = p_space_id
          and coalesce(child.is_active, true) = true
    ) then
        raise exception 'CATEGORY_HAS_ACTIVE_CHILDREN' using errcode = '23503';
    end if;

    return query
    update moneytrack.category_catalog c
       set is_active = false,
           updated_by_user_id = p_actor_user_id
     where c.id = p_category_id
       and c.space_id = p_space_id
    returning c.id, 'archived'::text;
end;
$function$;

comment on function moneytrack.category_delete_space_v1(bigint,bigint,bigint)
is 'UX-025 DELETE contract is history-safe archive. Category rows/ids are retained; active children block archive.';

commit;
