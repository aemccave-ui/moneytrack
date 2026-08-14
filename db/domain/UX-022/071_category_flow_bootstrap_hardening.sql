-- MoneyTrack — UX-022R3 — Category flow bootstrap hardening
-- Apply after 070_category_flow_settings.sql.
-- Source-only until explicit backend migration/deploy authorization.

begin;

-- Template user 0 has no posting history of its own. Infer flow_type only when
-- user-owned categories with the same code have one-sided historical usage.
-- Mixed or unused codes remain NULL instead of being guessed as expense.
with code_usage as (
    select
        c.code,
        count(*) filter (where t.transaction_type = 'income') as income_count,
        count(*) filter (where t.transaction_type in ('expense','adjustment')) as expense_count
    from moneytrack.category_catalog c
    join moneytrack.transactions t on t.category_id = c.id
    where c.user_id <> 0
    group by c.code
)
update moneytrack.category_catalog template
   set flow_type = case
       when u.income_count > 0 and u.expense_count = 0 then 'income'
       when u.expense_count > 0 and u.income_count = 0 then 'expense'
       else template.flow_type
   end
  from code_usage u
 where template.user_id = 0
   and template.code = u.code
   and nullif(btrim(template.flow_type), '') is null
   and (
       (u.income_count > 0 and u.expense_count = 0)
       or
       (u.expense_count > 0 and u.income_count = 0)
   );

-- Override the existing BE-DOM-002 bootstrap boundary after flow_type exists so
-- new user-owned category copies inherit the canonical template value. A NULL
-- template value remains NULL and is explicitly correctable by that user's
-- Settings screen; it is never silently coerced to expense.
create or replace function moneytrack.catalog_ensure_user_categories_v1(
    p_user_id bigint
)
returns table (
    status text,
    inserted_category_count integer,
    inserted_translation_count integer
)
language plpgsql
volatile
as $function$
declare
    v_parent_count integer := 0;
    v_child_count integer := 0;
    v_translation_count integer := 0;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if not exists (
        select 1 from moneytrack.app_users u where u.id = p_user_id
    ) then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('BE-DOM-002:catalog-bootstrap:' || p_user_id::text, 0)
    );

    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order, flow_type
    )
    select
        p_user_id,
        tc.code,
        null,
        tc.is_active,
        tc.sort_order,
        now(),
        tc.show_in_budget_report,
        tc.budget_sort_order,
        tc.flow_type
    from moneytrack.category_catalog tc
    where tc.user_id = 0
      and tc.parent_id is null
      and not exists (
          select 1
          from moneytrack.category_catalog existing
          where existing.user_id = p_user_id
            and existing.code = tc.code
      )
    on conflict (user_id, code) do nothing;

    get diagnostics v_parent_count = row_count;

    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order, flow_type
    )
    select
        p_user_id,
        tc.code,
        target_parent.id,
        tc.is_active,
        tc.sort_order,
        now(),
        tc.show_in_budget_report,
        tc.budget_sort_order,
        tc.flow_type
    from moneytrack.category_catalog tc
    join moneytrack.category_catalog template_parent
      on template_parent.id = tc.parent_id
     and template_parent.user_id = 0
    join moneytrack.category_catalog target_parent
      on target_parent.user_id = p_user_id
     and target_parent.code = template_parent.code
    where tc.user_id = 0
      and tc.parent_id is not null
      and not exists (
          select 1
          from moneytrack.category_catalog existing
          where existing.user_id = p_user_id
            and existing.code = tc.code
      )
    on conflict (user_id, code) do nothing;

    get diagnostics v_child_count = row_count;

    insert into moneytrack.category_catalog_translations (
        category_id, language_code, name
    )
    select
        target.id,
        tr.language_code,
        tr.name
    from moneytrack.category_catalog template
    join moneytrack.category_catalog target
      on target.user_id = p_user_id
     and target.code = template.code
    join moneytrack.category_catalog_translations tr
      on tr.category_id = template.id
    where template.user_id = 0
      and not exists (
          select 1
          from moneytrack.category_catalog_translations existing
          where existing.category_id = target.id
            and existing.language_code = tr.language_code
      );

    get diagnostics v_translation_count = row_count;

    return query
    select
        'ready'::text,
        (v_parent_count + v_child_count)::integer,
        v_translation_count::integer;
end;
$function$;

comment on function moneytrack.catalog_ensure_user_categories_v1(bigint)
is 'UX-022R3 hardened category bootstrap: copies canonical template hierarchy, translations and nullable migration-safe flow_type to new user-owned categories.';

commit;
