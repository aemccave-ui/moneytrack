-- MoneyTrack — UX-022R3 — Category flow metadata / Settings correction boundary
-- Source-only until an explicit backend migration/deploy gate is authorized.

begin;

alter table moneytrack.category_catalog
    add column if not exists flow_type text;

-- Bootstrap the new attribute from observed financial usage. Categories that have
-- never been used (or have mixed legacy usage) default to expense and can then be
-- corrected explicitly from Settings.
with usage as (
    select
        t.category_id,
        count(*) filter (where t.transaction_type = 'income') as income_count,
        count(*) filter (where t.transaction_type in ('expense','adjustment')) as expense_count
    from moneytrack.transactions t
    where t.category_id is not null
    group by t.category_id
)
update moneytrack.category_catalog c
   set flow_type = case
       when coalesce(u.income_count, 0) > 0 and coalesce(u.expense_count, 0) = 0 then 'income'
       else 'expense'
   end
  from usage u
 where c.id = u.category_id
   and nullif(btrim(c.flow_type), '') is null;

update moneytrack.category_catalog
   set flow_type = 'expense'
 where nullif(btrim(flow_type), '') is null;

alter table moneytrack.category_catalog
    alter column flow_type set default 'expense';
alter table moneytrack.category_catalog
    alter column flow_type set not null;

do $category_flow_constraint$
begin
    if not exists (
        select 1
        from pg_constraint
        where conrelid = 'moneytrack.category_catalog'::regclass
          and conname = 'category_catalog_flow_type_check'
    ) then
        alter table moneytrack.category_catalog
            add constraint category_catalog_flow_type_check
            check (flow_type in ('income','expense'));
    end if;
end;
$category_flow_constraint$;

create or replace function moneytrack.category_update_v1(
    p_telegram_user_id bigint,
    p_category_id bigint,
    p_name text,
    p_flow_type text
)
returns table (category jsonb)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
    v_language text;
    v_name text := nullif(btrim(p_name), '');
    v_flow text := lower(nullif(btrim(p_flow_type), ''));
    v_row moneytrack.category_catalog%rowtype;
begin
    if p_category_id is null then
        raise exception 'CATEGORY_ID_INVALID' using errcode = '22023';
    end if;
    if v_name is null then
        raise exception 'CATEGORY_NAME_REQUIRED' using errcode = '22023';
    end if;
    if v_flow not in ('income','expense') then
        raise exception 'CATEGORY_FLOW_TYPE_INVALID' using errcode = '22023';
    end if;

    select coalesce(s.language_code, u.language_code, 'ru')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings s on s.user_id = u.id
     where u.id = v_user_id;

    update moneytrack.category_catalog c
       set flow_type = v_flow
     where c.id = p_category_id
       and c.user_id = v_user_id
       and coalesce(c.is_active, true) = true
     returning * into v_row;

    if not found then
        raise exception 'CATEGORY_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    insert into moneytrack.category_catalog_translations(category_id, language_code, name)
    values (v_row.id, v_language, v_name)
    on conflict (category_id, language_code)
    do update set name = excluded.name;

    return query
    select jsonb_build_object(
        'id', v_row.id,
        'code', v_row.code,
        'parent_id', v_row.parent_id,
        'sort_order', v_row.sort_order,
        'name', v_name,
        'flow_type', v_row.flow_type,
        'editable', true
    );
end;
$function$;

comment on function moneytrack.category_update_v1(bigint,bigint,text,text)
is 'UX-022R3 Settings boundary for an owned active category: localized name + income/expense flow metadata.';

-- Keep the public transaction-reference response shape stable while extending
-- category JSON with flow_type/editable. User-owned rows win over template rows
-- with the same code.
create or replace function moneytrack.api_transaction_reference_read_model_v1(
    p_telegram_user_id bigint
)
returns table (
    user_found boolean,
    currencies jsonb,
    categories jsonb
)
language sql
stable
as $function$
    with user_ctx as (
        select
            u.id as internal_user_id,
            coalesce(s.language_code, u.language_code, 'en')::text as language_code
        from moneytrack.app_users u
        left join moneytrack.user_settings s
          on s.user_id = u.id
        where u.telegram_user_id = p_telegram_user_id
        limit 1
    ),
    currency_usage as (
        select upper(t.currency_original) as code, count(*)::bigint as usage_count
        from moneytrack.transactions t
        join user_ctx u on u.internal_user_id = t.user_id
        group by upper(t.currency_original)
    ),
    account_currency_usage as (
        select upper(a.currency_code) as code, count(*)::bigint as account_count
        from moneytrack.accounts a
        join user_ctx u on u.internal_user_id = a.user_id
        where coalesce(a.is_active, true) = true
        group by upper(a.currency_code)
    ),
    currency_rows as (
        select
            upper(c.code)::text as code,
            coalesce(cu.usage_count, 0)::bigint as usage_count,
            coalesce(au.account_count, 0)::bigint as account_count
        from moneytrack.currencies c
        left join currency_usage cu on cu.code = upper(c.code)
        left join account_currency_usage au on au.code = upper(c.code)
        where coalesce(c.is_active, true) = true
    ),
    category_candidates as (
        select
            c.id,
            c.code,
            c.user_id,
            coalesce(
                nullif(to_jsonb(c)->>'parent_id', '')::bigint,
                nullif(to_jsonb(c)->>'parent_category_id', '')::bigint
            ) as parent_id,
            coalesce(nullif(to_jsonb(c)->>'sort_order', '')::int, 0) as sort_order,
            coalesce(t_user.name, t_en.name, c.code) as name,
            coalesce(nullif(lower(to_jsonb(c)->>'flow_type'), ''), 'expense') as flow_type,
            (c.user_id = u.internal_user_id) as editable,
            row_number() over (
                partition by c.code
                order by (c.user_id = u.internal_user_id) desc, c.id
            ) as preference
        from moneytrack.category_catalog c
        cross join user_ctx u
        left join moneytrack.category_catalog_translations t_user
          on t_user.category_id = c.id
         and t_user.language_code = u.language_code
        left join moneytrack.category_catalog_translations t_en
          on t_en.category_id = c.id
         and t_en.language_code = 'en'
        where coalesce(c.is_active, true) = true
          and c.user_id in (0, u.internal_user_id)
    ),
    category_rows as (
        select * from category_candidates where preference = 1
    )
    select
        exists(select 1 from user_ctx) as user_found,
        coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'code', cr.code,
                    'usage_count', cr.usage_count,
                    'account_count', cr.account_count
                )
                order by ((cr.usage_count > 0) or (cr.account_count > 0)) desc, cr.code asc
            )
            from currency_rows cr
        ), '[]'::jsonb) as currencies,
        coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'id', cr.id,
                    'code', cr.code,
                    'name', cr.name,
                    'parent_id', cr.parent_id,
                    'sort_order', cr.sort_order,
                    'flow_type', cr.flow_type,
                    'editable', cr.editable
                )
                order by cr.sort_order, cr.name
            )
            from category_rows cr
        ), '[]'::jsonb) as categories;
$function$;

comment on function moneytrack.api_transaction_reference_read_model_v1(bigint)
is 'UX-022R3 transaction reference: used currencies first; localized categories include income/expense flow metadata and editability.';

commit;
