-- MoneyTrack — SPC-001A — Space-scoped bootstrap
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- New users and post-cutover bootstrap must initialize financial directories in
-- the Personal Space, not as a single user-owned directory. user_id remains
-- compatibility/actor provenance only; space_id is the financial tenant.

begin;

create or replace function moneytrack.catalog_ensure_space_categories_v1(
    p_actor_user_id bigint,
    p_space_id bigint
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
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    perform pg_advisory_xact_lock(
        hashtextextended('SPC-001:space-category-bootstrap:' || p_space_id::text, 0)
    );

    insert into moneytrack.category_catalog (
        user_id, space_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order,
        created_by_user_id, updated_by_user_id
    )
    select
        p_actor_user_id,
        p_space_id,
        tc.code,
        null,
        tc.is_active,
        tc.sort_order,
        now(),
        tc.show_in_budget_report,
        tc.budget_sort_order,
        p_actor_user_id,
        p_actor_user_id
    from moneytrack.category_catalog tc
    where tc.user_id = 0
      and tc.space_id is null
      and tc.parent_id is null
    on conflict (space_id, code) where space_id is not null do nothing;

    get diagnostics v_parent_count = row_count;

    insert into moneytrack.category_catalog (
        user_id, space_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order,
        created_by_user_id, updated_by_user_id
    )
    select
        p_actor_user_id,
        p_space_id,
        tc.code,
        target_parent.id,
        tc.is_active,
        tc.sort_order,
        now(),
        tc.show_in_budget_report,
        tc.budget_sort_order,
        p_actor_user_id,
        p_actor_user_id
    from moneytrack.category_catalog tc
    join moneytrack.category_catalog template_parent
      on template_parent.id = tc.parent_id
     and template_parent.user_id = 0
     and template_parent.space_id is null
    join moneytrack.category_catalog target_parent
      on target_parent.space_id = p_space_id
     and target_parent.code = template_parent.code
    where tc.user_id = 0
      and tc.space_id is null
      and tc.parent_id is not null
    on conflict (space_id, code) where space_id is not null do nothing;

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
      on target.space_id = p_space_id
     and target.code = template.code
    join moneytrack.category_catalog_translations tr
      on tr.category_id = template.id
    where template.user_id = 0
      and template.space_id is null
    on conflict (category_id, language_code) do nothing;

    get diagnostics v_translation_count = row_count;

    return query
    select
        'ready'::text,
        (v_parent_count + v_child_count)::integer,
        v_translation_count::integer;
end;
$function$;

comment on function moneytrack.catalog_ensure_space_categories_v1(bigint,bigint)
is 'SPC-001 category bootstrap. Copies global template categories into one financial Space; active membership is required and user_id is actor provenance only.';


create or replace function moneytrack.spc001_bootstrap_space_finance_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns table (
    space_id bigint,
    base_currency text,
    report_currency text,
    default_expense_account_id bigint,
    default_income_account_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_base_currency text;
    v_report_currency text;
    v_default_expense bigint;
    v_default_income bigint;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    perform pg_advisory_xact_lock(
        hashtextextended('SPC-001:space-finance-bootstrap:' || p_space_id::text, 0)
    );

    select
        coalesce(us.base_currency, u.default_currency, 'EUR'),
        coalesce(us.report_currency, us.base_currency, u.default_currency, 'EUR')
      into v_base_currency, v_report_currency
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id = u.id
     where u.id = 0;

    if v_base_currency is null then
        raise exception 'BOOTSTRAP_TEMPLATE_SETTINGS_MISSING' using errcode = 'P0001';
    end if;

    -- Top-level accounts.
    insert into moneytrack.accounts (
        user_id, space_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id,
        created_by_user_id, updated_by_user_id
    )
    select
        p_actor_user_id, p_space_id, ta.code, ta.name, ta.account_type,
        ta.currency_code, ta.is_active, now(), ta.sort_order, null,
        p_actor_user_id, p_actor_user_id
    from moneytrack.accounts ta
    where ta.user_id = 0
      and ta.space_id is null
      and ta.parent_id is null
    on conflict (space_id, code) where space_id is not null do nothing;

    -- Child accounts preserve the template parent topology inside the Space.
    insert into moneytrack.accounts (
        user_id, space_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id,
        created_by_user_id, updated_by_user_id
    )
    select
        p_actor_user_id, p_space_id, child.code, child.name, child.account_type,
        child.currency_code, child.is_active, now(), child.sort_order,
        target_parent.id, p_actor_user_id, p_actor_user_id
    from moneytrack.accounts child
    join moneytrack.accounts template_parent
      on template_parent.id = child.parent_id
     and template_parent.user_id = 0
     and template_parent.space_id is null
    join moneytrack.accounts target_parent
      on target_parent.space_id = p_space_id
     and target_parent.code = template_parent.code
    where child.user_id = 0
      and child.space_id is null
      and child.parent_id is not null
    on conflict (space_id, code) where space_id is not null do nothing;

    perform 1
    from moneytrack.catalog_ensure_space_categories_v1(p_actor_user_id, p_space_id);

    insert into moneytrack.space_financial_settings(
        space_id, base_currency, report_currency, created_at, updated_at
    ) values (
        p_space_id, v_base_currency, v_report_currency, now(), now()
    )
    on conflict (space_id) do nothing;

    -- Per-currency defaults follow global template mappings by account code.
    insert into moneytrack.space_default_accounts(
        space_id, currency_code, account_id, created_at, updated_at
    )
    select
        p_space_id,
        td.currency_code,
        target.id,
        now(),
        now()
    from moneytrack.user_default_accounts td
    join moneytrack.accounts template_account
      on template_account.id = td.account_id
     and template_account.user_id = 0
     and template_account.space_id is null
    join moneytrack.accounts target
      on target.space_id = p_space_id
     and target.code = template_account.code
    where td.user_id = 0
    on conflict (space_id, currency_code) do update
       set account_id = excluded.account_id,
           updated_at = now();

    select target_expense.id, target_income.id
      into v_default_expense, v_default_income
      from moneytrack.user_settings template_settings
      left join moneytrack.accounts template_expense
        on template_expense.id = template_settings.default_expense_account_id
       and template_expense.user_id = 0
       and template_expense.space_id is null
      left join moneytrack.accounts target_expense
        on target_expense.space_id = p_space_id
       and target_expense.code = template_expense.code
      left join moneytrack.accounts template_income
        on template_income.id = template_settings.default_income_account_id
       and template_income.user_id = 0
       and template_income.space_id is null
      left join moneytrack.accounts target_income
        on target_income.space_id = p_space_id
       and target_income.code = template_income.code
     where template_settings.user_id = 0;

    update moneytrack.space_financial_settings s
       set default_expense_account_id = coalesce(s.default_expense_account_id, v_default_expense),
           default_income_account_id = coalesce(s.default_income_account_id, v_default_income),
           updated_at = now()
     where s.space_id = p_space_id;

    return query
    select s.space_id, s.base_currency, s.report_currency,
           s.default_expense_account_id, s.default_income_account_id
    from moneytrack.space_financial_settings s
    where s.space_id = p_space_id;
end;
$function$;

comment on function moneytrack.spc001_bootstrap_space_finance_v1(bigint,bigint)
is 'SPC-001 idempotent financial bootstrap for one Space. Clones account/category/default templates into Space-local instances.';


create or replace function moneytrack.spc001_user_bootstrap_v1(
    p_telegram_user_id bigint,
    p_username text,
    p_first_name text,
    p_telegram_language_code text
)
returns table (
    user_id bigint,
    telegram_user_id bigint,
    language_code text,
    space_id bigint,
    workspace_role text,
    base_currency text,
    report_currency text,
    default_expense_account_id bigint,
    default_income_account_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_language text;
    v_base text;
    v_personal_space bigint;
    v_current_space bigint;
    v_role text;
    v_fin record;
begin
    if p_telegram_user_id is null then
        raise exception 'TELEGRAM_USER_ID_REQUIRED' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('SPC-001:user-bootstrap:' || p_telegram_user_id::text, 0)
    );

    select
        coalesce(l.code, ts.language_code, tu.language_code, 'en'),
        coalesce(ts.base_currency, tu.default_currency, 'EUR')
      into v_language, v_base
      from moneytrack.app_users tu
      left join moneytrack.user_settings ts on ts.user_id = tu.id
      left join moneytrack.languages l
        on l.code = nullif(btrim(p_telegram_language_code), '')
     where tu.id = 0;

    if v_base is null then
        raise exception 'BOOTSTRAP_TEMPLATE_SETTINGS_MISSING' using errcode = 'P0001';
    end if;

    insert into moneytrack.app_users(
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        p_telegram_user_id,
        nullif(btrim(p_username), ''),
        nullif(btrim(p_first_name), ''),
        v_language,
        v_base
    )
    on conflict (telegram_user_id) do update
       set username = excluded.username,
           first_name = excluded.first_name,
           language_code = coalesce(moneytrack.app_users.language_code, excluded.language_code),
           default_currency = coalesce(moneytrack.app_users.default_currency, excluded.default_currency)
    returning id into v_user_id;

    v_personal_space := moneytrack.spc001_personal_space_for_user_v1(v_user_id);

    -- user_settings remains the home for USER_GLOBAL language + current Space.
    -- Financial currencies/default accounts are canonical in Space settings.
    insert into moneytrack.user_settings(
        user_id, language_code, base_currency, report_currency,
        current_workspace_id, created_at, updated_at
    ) values (
        v_user_id, v_language, v_base, v_base,
        v_personal_space, now(), now()
    )
    on conflict (user_id) do update
       set language_code = coalesce(moneytrack.user_settings.language_code, excluded.language_code),
           current_workspace_id = coalesce(moneytrack.user_settings.current_workspace_id, excluded.current_workspace_id),
           updated_at = now();

    select us.current_workspace_id
      into v_current_space
      from moneytrack.user_settings us
     where us.user_id = v_user_id;

    -- A stale/non-member current pointer is never trusted.
    if v_current_space is null or not exists (
        select 1
        from moneytrack.workspace_members wm
        join moneytrack.workspaces w on w.id = wm.workspace_id
        where wm.workspace_id = v_current_space
          and wm.user_id = v_user_id
          and coalesce(wm.is_active, true) = true
          and coalesce(w.is_active, true) = true
    ) then
        v_current_space := v_personal_space;
        update moneytrack.user_settings
           set current_workspace_id = v_current_space,
               updated_at = now()
         where user_id = v_user_id;
    end if;

    -- Personal finance is always initialized. If current Space is shared and
    -- already exists, its owner/admin creation path is responsible for its
    -- financial bootstrap; do not duplicate it here.
    perform 1 from moneytrack.spc001_bootstrap_space_finance_v1(v_user_id, v_personal_space);

    if not exists (
        select 1 from moneytrack.space_financial_settings s where s.space_id = v_current_space
    ) then
        perform 1 from moneytrack.spc001_bootstrap_space_finance_v1(v_user_id, v_current_space);
    end if;

    select wm.role
      into v_role
      from moneytrack.workspace_members wm
     where wm.workspace_id = v_current_space
       and wm.user_id = v_user_id
       and coalesce(wm.is_active, true) = true;

    select * into v_fin
      from moneytrack.space_financial_settings s
     where s.space_id = v_current_space;

    return query
    select
        v_user_id,
        p_telegram_user_id,
        coalesce((select us.language_code from moneytrack.user_settings us where us.user_id = v_user_id), v_language),
        v_current_space,
        v_role,
        v_fin.base_currency,
        v_fin.report_currency,
        v_fin.default_expense_account_id,
        v_fin.default_income_account_id;
end;
$function$;

comment on function moneytrack.spc001_user_bootstrap_v1(bigint,text,text,text)
is 'SPC-001 Telegram identity bootstrap. Creates/repairs Personal Space membership and Space-local finance; current Space pointer is validated against active membership.';

commit;
