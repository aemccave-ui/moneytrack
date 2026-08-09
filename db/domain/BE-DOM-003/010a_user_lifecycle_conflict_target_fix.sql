-- MoneyTrack — BE-DOM-003 — PL/pgSQL conflict-target disambiguation
--
-- RETURNS TABLE output names become PL/pgSQL variables. PostgreSQL can then
-- interpret bare ON CONFLICT column names as either output variables or table
-- columns. Recreate the affected boundaries using named constraints where
-- available and targetless DO NOTHING for the manually indexed account key.

begin;

create or replace function moneytrack.user_bootstrap_v1(
    p_telegram_user_id bigint,
    p_username text,
    p_first_name text,
    p_telegram_language_code text
)
returns table (
    user_id bigint,
    telegram_user_id bigint,
    language_code text,
    base_currency text,
    report_currency text,
    workspace_id bigint,
    workspace_role text,
    default_expense_account_id bigint,
    default_income_account_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_user_id bigint;
    v_resolved_language text;
    v_resolved_base_currency text;
    v_resolved_report_currency text;
    v_personal_workspace_id bigint;
    v_current_workspace_id bigint;
    v_default_expense_account_id bigint;
    v_default_income_account_id bigint;
begin
    if p_telegram_user_id is null then
        raise exception 'TELEGRAM_USER_ID_REQUIRED' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('BE-DOM-003:user-bootstrap:' || p_telegram_user_id::text, 0)
    );

    select
        coalesce(l.code, ts.language_code, tu.language_code),
        coalesce(ts.base_currency, tu.default_currency),
        coalesce(ts.report_currency, ts.base_currency, tu.default_currency)
      into
        v_resolved_language,
        v_resolved_base_currency,
        v_resolved_report_currency
      from moneytrack.app_users tu
      join moneytrack.user_settings ts
        on ts.user_id = tu.id
      left join moneytrack.languages l
        on l.code = nullif(btrim(p_telegram_language_code), '')
     where tu.id = 0;

    if v_resolved_base_currency is null then
        raise exception 'BOOTSTRAP_TEMPLATE_SETTINGS_MISSING' using errcode = 'P0001';
    end if;

    insert into moneytrack.app_users (
        telegram_user_id,
        username,
        first_name,
        language_code,
        default_currency
    ) values (
        p_telegram_user_id,
        nullif(btrim(p_username), ''),
        nullif(btrim(p_first_name), ''),
        v_resolved_language,
        v_resolved_base_currency
    )
    on conflict on constraint app_users_telegram_user_id_key do update
    set
        username = excluded.username,
        first_name = excluded.first_name,
        language_code = coalesce(moneytrack.app_users.language_code, excluded.language_code),
        default_currency = coalesce(moneytrack.app_users.default_currency, excluded.default_currency)
    returning id into v_user_id;

    select w.id
      into v_personal_workspace_id
      from moneytrack.workspaces w
     where w.owner_user_id = v_user_id
       and w.workspace_type = 'personal'
       and coalesce(w.is_active, true) = true
     order by w.id
     limit 1;

    if v_personal_workspace_id is null then
        insert into moneytrack.workspaces (
            name,
            workspace_type,
            owner_user_id,
            is_active,
            created_at
        ) values (
            'Personal',
            'personal',
            v_user_id,
            true,
            now()
        )
        returning id into v_personal_workspace_id;
    end if;

    insert into moneytrack.workspace_members (
        workspace_id,
        user_id,
        role,
        is_active,
        created_at
    ) values (
        v_personal_workspace_id,
        v_user_id,
        'owner',
        true,
        now()
    )
    on conflict on constraint workspace_members_pkey do update
    set role = 'owner', is_active = true;

    insert into moneytrack.accounts (
        user_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id
    )
    select
        v_user_id,
        ta.code,
        ta.name,
        ta.account_type,
        ta.currency_code,
        ta.is_active,
        now(),
        ta.sort_order,
        null
    from moneytrack.accounts ta
    where ta.user_id = 0
      and ta.parent_id is null
    on conflict do nothing;

    insert into moneytrack.accounts (
        user_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id
    )
    select
        v_user_id,
        child.code,
        child.name,
        child.account_type,
        child.currency_code,
        child.is_active,
        now(),
        child.sort_order,
        target_parent.id
    from moneytrack.accounts child
    join moneytrack.accounts template_parent
      on template_parent.id = child.parent_id
     and template_parent.user_id = 0
    join moneytrack.accounts target_parent
      on target_parent.user_id = v_user_id
     and target_parent.code = template_parent.code
    where child.user_id = 0
      and child.parent_id is not null
    on conflict do nothing;

    insert into moneytrack.user_default_accounts (
        user_id,
        currency_code,
        account_id
    )
    select
        v_user_id,
        template_default.currency_code,
        target_account.id
    from moneytrack.user_default_accounts template_default
    join moneytrack.accounts template_account
      on template_account.id = template_default.account_id
     and template_account.user_id = 0
    join moneytrack.accounts target_account
      on target_account.user_id = v_user_id
     and target_account.code = template_account.code
    where template_default.user_id = 0
    on conflict on constraint user_default_accounts_pkey do nothing;

    perform 1
      from moneytrack.catalog_ensure_user_categories_v1(v_user_id);

    select
        target_expense.id,
        target_income.id
      into
        v_default_expense_account_id,
        v_default_income_account_id
      from moneytrack.user_settings template_settings
      left join moneytrack.accounts template_expense
        on template_expense.id = template_settings.default_expense_account_id
      left join moneytrack.accounts target_expense
        on target_expense.user_id = v_user_id
       and target_expense.code = template_expense.code
      left join moneytrack.accounts template_income
        on template_income.id = template_settings.default_income_account_id
      left join moneytrack.accounts target_income
        on target_income.user_id = v_user_id
       and target_income.code = template_income.code
     where template_settings.user_id = 0;

    insert into moneytrack.user_settings (
        user_id,
        language_code,
        base_currency,
        report_currency,
        default_expense_account_id,
        default_income_account_id,
        current_workspace_id,
        created_at,
        updated_at
    ) values (
        v_user_id,
        v_resolved_language,
        v_resolved_base_currency,
        v_resolved_report_currency,
        v_default_expense_account_id,
        v_default_income_account_id,
        v_personal_workspace_id,
        now(),
        now()
    )
    on conflict on constraint user_settings_pkey do update
    set
        language_code = coalesce(moneytrack.user_settings.language_code, excluded.language_code),
        base_currency = coalesce(moneytrack.user_settings.base_currency, excluded.base_currency),
        report_currency = coalesce(moneytrack.user_settings.report_currency, excluded.report_currency),
        default_expense_account_id = coalesce(
            moneytrack.user_settings.default_expense_account_id,
            excluded.default_expense_account_id
        ),
        default_income_account_id = coalesce(
            moneytrack.user_settings.default_income_account_id,
            excluded.default_income_account_id
        ),
        current_workspace_id = coalesce(
            moneytrack.user_settings.current_workspace_id,
            excluded.current_workspace_id
        ),
        updated_at = now();

    select
        us.language_code,
        us.base_currency,
        us.report_currency,
        us.current_workspace_id,
        us.default_expense_account_id,
        us.default_income_account_id
      into
        v_resolved_language,
        v_resolved_base_currency,
        v_resolved_report_currency,
        v_current_workspace_id,
        v_default_expense_account_id,
        v_default_income_account_id
      from moneytrack.user_settings us
     where us.user_id = v_user_id;

    return query
    select
        v_user_id,
        p_telegram_user_id,
        v_resolved_language,
        v_resolved_base_currency,
        v_resolved_report_currency,
        v_current_workspace_id,
        wm.role,
        v_default_expense_account_id,
        v_default_income_account_id
    from (select 1) seed
    left join moneytrack.workspace_members wm
      on wm.workspace_id = v_current_workspace_id
     and wm.user_id = v_user_id
     and wm.is_active = true;
end;
$function$;

comment on function moneytrack.user_bootstrap_v1(bigint,text,text,text)
is 'BE-DOM-003 canonical idempotent user bootstrap boundary. Serializes Telegram identity creation, personal workspace membership, template account/default/category bootstrap and settings initialization while preserving existing user state. Conflict targets are explicitly disambiguated from RETURNS TABLE output variables.';


create or replace function moneytrack.user_set_default_account_v1(
    p_user_id bigint,
    p_currency_code text,
    p_account_hint text
)
returns table (
    currency_code text,
    account_hint text,
    account_name text,
    account_code text,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_currency text := nullif(btrim(p_currency_code), '');
    v_hint text := nullif(btrim(p_account_hint), '');
    v_normalized_hint text;
    v_currency_valid boolean := false;
    v_account_id bigint;
    v_account_name text;
    v_account_code text;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if v_hint is not null then
        v_normalized_hint := lower(
            regexp_replace(v_hint, '[^a-zA-Zа-яА-Я0-9]+', '', 'g')
        );
    end if;

    if v_currency is not null then
        select exists (
            select 1
            from moneytrack.currencies c
            where c.code = v_currency
              and coalesce(c.is_active, true) = true
        ) into v_currency_valid;
    end if;

    if v_currency is not null and v_hint is not null and v_currency_valid then
        select a.id, a.name, a.code
          into v_account_id, v_account_name, v_account_code
          from moneytrack.accounts a
         where a.user_id = p_user_id
           and a.currency_code = v_currency
           and coalesce(a.is_active, true) = true
           and (
                lower(a.code) = lower(v_hint)
                or lower(a.name) = lower(v_hint)
                or lower(regexp_replace(a.name, '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) = v_normalized_hint
                or lower(regexp_replace(a.name, '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) like '%' || v_normalized_hint || '%'
                or v_normalized_hint like '%' || lower(regexp_replace(a.name, '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) || '%'
           )
         order by
             case
                 when lower(a.code) = lower(v_hint) then 0
                 when lower(a.name) = lower(v_hint) then 1
                 when lower(regexp_replace(a.name, '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) = v_normalized_hint then 2
                 else 3
             end,
             length(a.name),
             a.id
         limit 1;
    end if;

    if v_currency is null or v_hint is null then
        return query select v_currency, v_hint, v_account_name, v_account_code, 'invalid_command'::text;
        return;
    end if;

    if not v_currency_valid then
        return query select v_currency, v_hint, v_account_name, v_account_code, 'invalid_currency'::text;
        return;
    end if;

    if v_account_id is null then
        return query select v_currency, v_hint, null::text, null::text, 'account_not_found'::text;
        return;
    end if;

    insert into moneytrack.user_default_accounts (
        user_id,
        currency_code,
        account_id
    ) values (
        p_user_id,
        v_currency,
        v_account_id
    )
    on conflict on constraint user_default_accounts_pkey do update
    set account_id = excluded.account_id;

    return query select v_currency, v_hint, v_account_name, v_account_code, 'updated'::text;
end;
$function$;

comment on function moneytrack.user_set_default_account_v1(bigint,text,text)
is 'BE-DOM-003 default-account preference boundary. Resolves only active accounts owned by the authenticated user in the requested currency and upserts the per-currency default. Conflict target is explicitly disambiguated from RETURNS TABLE output variables.';

commit;
