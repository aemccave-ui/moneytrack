-- MoneyTrack — SPC-001A — Space tenancy foundation
--
-- SOURCE ONLY until the SPC migration/runtime gates authorize controlled apply.
-- Physical `workspaces` / `workspace_members` are reused as the backing tables
-- for the product concept Space. `space_id` is the financial tenancy boundary;
-- legacy financial `user_id` remains compatibility/actor provenance only and
-- MUST NOT be used by SPC boundaries as financial ownership.

begin;

-- ---------------------------------------------------------------------------
-- 0. Fail closed if the canonical dependency schema is not present.
-- ---------------------------------------------------------------------------

do $preflight$
declare
    v_missing text[] := '{}'::text[];
    v_name text;
begin
    foreach v_name in array array[
        'app_users',
        'workspaces',
        'workspace_members',
        'user_settings',
        'accounts',
        'transactions',
        'transfers',
        'receipts',
        'receipt_items',
        'category_catalog',
        'product_catalog',
        'budget_rules',
        'filter_presets'
    ] loop
        if to_regclass('moneytrack.' || v_name) is null then
            v_missing := array_append(v_missing, v_name);
        end if;
    end loop;

    if cardinality(v_missing) > 0 then
        raise exception 'SPC001_REQUIRED_TABLES_MISSING: %', array_to_string(v_missing, ',');
    end if;
end;
$preflight$;

-- ---------------------------------------------------------------------------
-- 1. Canonical Space ownership columns.
-- ---------------------------------------------------------------------------

alter table moneytrack.accounts
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists created_by_user_id bigint references moneytrack.app_users(id) on delete restrict,
    add column if not exists updated_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.transactions
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists created_by_user_id bigint references moneytrack.app_users(id) on delete restrict,
    add column if not exists updated_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.transfers
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists created_by_user_id bigint references moneytrack.app_users(id) on delete restrict,
    add column if not exists updated_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.receipts
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists captured_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.category_catalog
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists created_by_user_id bigint references moneytrack.app_users(id) on delete restrict,
    add column if not exists updated_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.product_catalog
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists created_by_user_id bigint references moneytrack.app_users(id) on delete restrict,
    add column if not exists updated_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.budget_rules
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete restrict,
    add column if not exists created_by_user_id bigint references moneytrack.app_users(id) on delete restrict,
    add column if not exists updated_by_user_id bigint references moneytrack.app_users(id) on delete restrict;

alter table moneytrack.filter_presets
    add column if not exists space_id bigint references moneytrack.workspaces(id) on delete cascade;

create index if not exists ix_accounts_space_active
    on moneytrack.accounts(space_id, is_active, id)
    where space_id is not null;
create index if not exists ix_transactions_space_date
    on moneytrack.transactions(space_id, transaction_date desc, id desc)
    where space_id is not null;
create index if not exists ix_transfers_space_date
    on moneytrack.transfers(space_id, transfer_date desc, id desc)
    where space_id is not null;
create index if not exists ix_receipts_space_transaction
    on moneytrack.receipts(space_id, transaction_id)
    where space_id is not null;
create index if not exists ix_category_catalog_space_active
    on moneytrack.category_catalog(space_id, is_active, id)
    where space_id is not null;
create index if not exists ix_product_catalog_space_active
    on moneytrack.product_catalog(space_id, is_active, id)
    where space_id is not null;
create index if not exists ix_budget_rules_space_active
    on moneytrack.budget_rules(space_id, is_active, id)
    where space_id is not null;
create index if not exists ix_filter_presets_user_space
    on moneytrack.filter_presets(user_id, space_id, created_at, id)
    where space_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Space-owned financial defaults.
-- Existing user_settings financial columns and user_default_accounts remain
-- compatibility surfaces until the API/domain cutover, but they cease to be
-- canonical after SPC runtime cutover.
-- ---------------------------------------------------------------------------

create table if not exists moneytrack.space_financial_settings (
    space_id bigint primary key references moneytrack.workspaces(id) on delete cascade,
    base_currency text not null references moneytrack.currencies(code),
    report_currency text not null references moneytrack.currencies(code),
    default_expense_account_id bigint references moneytrack.accounts(id) on delete set null,
    default_income_account_id bigint references moneytrack.accounts(id) on delete set null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create table if not exists moneytrack.space_default_accounts (
    space_id bigint not null references moneytrack.workspaces(id) on delete cascade,
    currency_code text not null references moneytrack.currencies(code),
    account_id bigint not null references moneytrack.accounts(id) on delete restrict,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    primary key (space_id, currency_code)
);

-- ---------------------------------------------------------------------------
-- 3. Canonical active membership boundary.
-- Owner role is intentionally NOT inspected for financial authorization.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.assert_space_member_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns bigint
language plpgsql
stable
as $function$
begin
    if p_actor_user_id is null then
        raise exception 'ACTOR_REQUIRED' using errcode = '22023';
    end if;
    if p_space_id is null then
        raise exception 'SPACE_REQUIRED' using errcode = '22023';
    end if;

    if not exists (
        select 1
        from moneytrack.workspaces w
        join moneytrack.workspace_members wm
          on wm.workspace_id = w.id
         and wm.user_id = p_actor_user_id
         and coalesce(wm.is_active, true) = true
        where w.id = p_space_id
          and coalesce(w.is_active, true) = true
    ) then
        raise exception 'SPACE_NOT_FOUND_OR_NOT_MEMBER' using errcode = 'P0002';
    end if;

    return p_space_id;
end;
$function$;

comment on function moneytrack.assert_space_member_v1(bigint,bigint)
is 'SPC-001 canonical financial authorization primitive. Active membership, not owner role, grants ordinary Space financial access.';

create or replace function moneytrack.assert_space_owner_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns bigint
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id, p_space_id);

    if not exists (
        select 1
        from moneytrack.workspaces w
        where w.id = p_space_id
          and w.owner_user_id = p_actor_user_id
          and coalesce(w.is_active, true) = true
    ) then
        raise exception 'SPACE_OWNER_REQUIRED' using errcode = '42501';
    end if;

    return p_space_id;
end;
$function$;

comment on function moneytrack.assert_space_owner_v1(bigint,bigint)
is 'SPC-001 administration-only owner assertion. Must not be required by ordinary financial CRUD.';

-- ---------------------------------------------------------------------------
-- 4. Resolve exactly one initial Personal Space for legacy users.
-- Fail closed on duplicate active personal workspaces.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.spc001_personal_space_for_user_v1(
    p_user_id bigint
)
returns bigint
language plpgsql
volatile
as $function$
declare
    v_count integer;
    v_space_id bigint;
begin
    if p_user_id is null or p_user_id = 0 then
        raise exception 'LEGACY_USER_REQUIRED' using errcode = '22023';
    end if;

    perform pg_advisory_xact_lock(
        hashtextextended('SPC-001:personal-space:' || p_user_id::text, 0)
    );

    select count(*)::integer, min(w.id)
      into v_count, v_space_id
      from moneytrack.workspaces w
     where w.owner_user_id = p_user_id
       and w.workspace_type = 'personal'
       and coalesce(w.is_active, true) = true;

    if v_count > 1 then
        raise exception 'SPC001_MULTIPLE_ACTIVE_PERSONAL_SPACES: user=%', p_user_id
            using errcode = '23505';
    end if;

    if v_count = 0 then
        insert into moneytrack.workspaces(
            name, workspace_type, owner_user_id, is_active, created_at
        ) values (
            'Personal', 'personal', p_user_id, true, now()
        ) returning id into v_space_id;
    end if;

    insert into moneytrack.workspace_members(
        workspace_id, user_id, role, is_active, created_at
    ) values (
        v_space_id, p_user_id, 'owner', true, now()
    )
    on conflict (workspace_id, user_id) do update
       set is_active = true,
           role = 'owner';

    return v_space_id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Deterministic/idempotent existing-user migration.
-- Template sentinel user 0 remains GLOBAL_PLATFORM and receives no Space.
-- ---------------------------------------------------------------------------

do $legacy_migration$
declare
    r record;
    v_space_id bigint;
begin
    for r in
        select u.id
        from moneytrack.app_users u
        where u.id <> 0
        order by u.id
    loop
        v_space_id := moneytrack.spc001_personal_space_for_user_v1(r.id);

        update moneytrack.accounts a
           set space_id = coalesce(a.space_id, v_space_id),
               created_by_user_id = coalesce(a.created_by_user_id, a.user_id),
               updated_by_user_id = coalesce(a.updated_by_user_id, a.user_id)
         where a.user_id = r.id;

        update moneytrack.transactions t
           set space_id = coalesce(t.space_id, v_space_id),
               created_by_user_id = coalesce(t.created_by_user_id, t.user_id),
               updated_by_user_id = coalesce(t.updated_by_user_id, t.user_id)
         where t.user_id = r.id;

        update moneytrack.transfers t
           set space_id = coalesce(t.space_id, v_space_id),
               created_by_user_id = coalesce(t.created_by_user_id, t.user_id),
               updated_by_user_id = coalesce(t.updated_by_user_id, t.user_id)
         where t.user_id = r.id;

        update moneytrack.receipts x
           set space_id = coalesce(x.space_id, v_space_id),
               captured_by_user_id = coalesce(x.captured_by_user_id, x.user_id)
         where x.user_id = r.id;

        update moneytrack.category_catalog c
           set space_id = coalesce(c.space_id, v_space_id),
               created_by_user_id = coalesce(c.created_by_user_id, c.user_id),
               updated_by_user_id = coalesce(c.updated_by_user_id, c.user_id)
         where c.user_id = r.id;

        update moneytrack.product_catalog p
           set space_id = coalesce(p.space_id, v_space_id),
               created_by_user_id = coalesce(p.created_by_user_id, p.user_id),
               updated_by_user_id = coalesce(p.updated_by_user_id, p.user_id)
         where p.user_id = r.id;

        update moneytrack.budget_rules b
           set space_id = coalesce(b.space_id, v_space_id),
               created_by_user_id = coalesce(b.created_by_user_id, b.user_id),
               updated_by_user_id = coalesce(b.updated_by_user_id, b.user_id)
         where b.user_id = r.id;

        update moneytrack.filter_presets p
           set space_id = coalesce(p.space_id, v_space_id)
         where p.user_id = r.id;

        insert into moneytrack.space_financial_settings(
            space_id,
            base_currency,
            report_currency,
            default_expense_account_id,
            default_income_account_id,
            created_at,
            updated_at
        )
        select
            v_space_id,
            coalesce(us.base_currency, u.default_currency, 'EUR'),
            coalesce(us.report_currency, us.base_currency, u.default_currency, 'EUR'),
            us.default_expense_account_id,
            us.default_income_account_id,
            now(),
            now()
        from moneytrack.app_users u
        left join moneytrack.user_settings us on us.user_id = u.id
        where u.id = r.id
        on conflict (space_id) do update
           set base_currency = excluded.base_currency,
               report_currency = excluded.report_currency,
               default_expense_account_id = coalesce(
                   moneytrack.space_financial_settings.default_expense_account_id,
                   excluded.default_expense_account_id
               ),
               default_income_account_id = coalesce(
                   moneytrack.space_financial_settings.default_income_account_id,
                   excluded.default_income_account_id
               ),
               updated_at = now();

        insert into moneytrack.space_default_accounts(
            space_id, currency_code, account_id, created_at, updated_at
        )
        select
            v_space_id,
            uda.currency_code,
            uda.account_id,
            now(),
            now()
        from moneytrack.user_default_accounts uda
        where uda.user_id = r.id
        on conflict (space_id, currency_code) do update
           set account_id = excluded.account_id,
               updated_at = now();
    end loop;
end;
$legacy_migration$;

-- ---------------------------------------------------------------------------
-- 6. Reconciliation MUST pass before this transaction can commit.
-- ---------------------------------------------------------------------------

do $reconcile$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
begin
    select count(*) into v_count
    from moneytrack.app_users u
    where u.id <> 0
      and not exists (
          select 1
          from moneytrack.workspaces w
          join moneytrack.workspace_members wm
            on wm.workspace_id = w.id
           and wm.user_id = u.id
           and coalesce(wm.is_active, true) = true
          where w.owner_user_id = u.id
            and w.workspace_type = 'personal'
            and coalesce(w.is_active, true) = true
      );
    if v_count <> 0 then v_errors := array_append(v_errors, 'owner_membership=' || v_count); end if;

    select count(*) into v_count from moneytrack.accounts a where a.user_id <> 0 and a.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'accounts_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.transactions t where t.user_id <> 0 and t.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'transactions_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.transfers t where t.user_id <> 0 and t.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'transfers_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.receipts r where r.user_id <> 0 and r.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'receipts_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog c where c.user_id <> 0 and c.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'categories_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog p where p.user_id <> 0 and p.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'products_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.budget_rules b where b.user_id <> 0 and b.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'budgets_missing_space=' || v_count); end if;
    select count(*) into v_count from moneytrack.filter_presets p where p.user_id <> 0 and p.space_id is null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'filter_presets_missing_space=' || v_count); end if;

    -- Template/platform rows must not accidentally acquire a user Space.
    select count(*) into v_count from moneytrack.accounts a where a.user_id = 0 and a.space_id is not null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'template_accounts_space_leak=' || v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog c where c.user_id = 0 and c.space_id is not null;
    if v_count <> 0 then v_errors := array_append(v_errors, 'template_categories_space_leak=' || v_count); end if;

    -- Financial references must already reconcile to one Space before the
    -- same-Space mutation triggers are enabled.
    select count(*) into v_count
    from moneytrack.transactions t
    join moneytrack.accounts a on a.id = t.account_id
    where t.space_id is distinct from a.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'transaction_account_cross_space=' || v_count); end if;

    select count(*) into v_count
    from moneytrack.transactions t
    join moneytrack.category_catalog c on c.id = t.category_id
    where t.category_id is not null
      and t.space_id is distinct from c.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'transaction_category_cross_space=' || v_count); end if;

    select count(*) into v_count
    from moneytrack.transfers t
    join moneytrack.accounts a1 on a1.id = t.from_account_id
    join moneytrack.accounts a2 on a2.id = t.to_account_id
    where t.space_id is distinct from a1.space_id
       or t.space_id is distinct from a2.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'transfer_account_cross_space=' || v_count); end if;

    select count(*) into v_count
    from moneytrack.receipts r
    join moneytrack.transactions t on t.id = r.transaction_id
    where r.space_id is distinct from t.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'receipt_transaction_cross_space=' || v_count); end if;

    select count(*) into v_count
    from moneytrack.budget_rules b
    join moneytrack.category_catalog c on c.id = b.category_id
    where b.category_id is not null
      and b.space_id is distinct from c.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'budget_category_cross_space=' || v_count); end if;

    select count(*) into v_count
    from moneytrack.space_default_accounts d
    join moneytrack.accounts a on a.id = d.account_id
    where d.space_id is distinct from a.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'default_account_cross_space=' || v_count); end if;

    select count(*) into v_count
    from moneytrack.space_financial_settings s
    join moneytrack.accounts a on a.id in (s.default_expense_account_id, s.default_income_account_id)
    where a.space_id is distinct from s.space_id;
    if v_count <> 0 then v_errors := array_append(v_errors, 'financial_setting_account_cross_space=' || v_count); end if;

    if cardinality(v_errors) > 0 then
        raise exception 'SPC001_MIGRATION_RECONCILIATION_FAILED: %', array_to_string(v_errors, ';');
    end if;
end;
$reconcile$;

-- ---------------------------------------------------------------------------
-- 7. Same-Space mutation invariant trigger.
-- The trigger deliberately authorizes no actor. Authorization belongs in the
-- domain boundary via assert_space_member_v1; this trigger protects relational
-- consistency even if a caller passes a foreign finance id.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.spc001_assert_same_space_row_v1()
returns trigger
language plpgsql
as $function$
declare
    v_ref_space bigint;
    v_receipt_space bigint;
begin
    if tg_table_name in ('accounts','transactions','transfers','receipts','category_catalog','product_catalog','budget_rules') then
        if new.user_id = 0 then
            if new.space_id is not null then
                raise exception 'SPC001_GLOBAL_TEMPLATE_CANNOT_HAVE_SPACE' using errcode = '23514';
            end if;
            return new;
        end if;
        if new.space_id is null then
            raise exception 'SPC001_SPACE_REQUIRED' using errcode = '23514';
        end if;
    end if;

    if tg_table_name = 'accounts' and new.parent_id is not null then
        select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.parent_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_ACCOUNT_PARENT_CROSS_SPACE' using errcode = '23514';
        end if;
    elsif tg_table_name = 'transactions' then
        select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_TRANSACTION_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;
        if new.category_id is not null then
            select c.space_id into v_ref_space from moneytrack.category_catalog c where c.id = new.category_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_TRANSACTION_CATEGORY_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;
    elsif tg_table_name = 'transfers' then
        select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.from_account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_TRANSFER_FROM_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;
        select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.to_account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_TRANSFER_TO_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;
    elsif tg_table_name = 'receipts' and new.transaction_id is not null then
        select t.space_id into v_ref_space from moneytrack.transactions t where t.id = new.transaction_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_RECEIPT_TRANSACTION_CROSS_SPACE' using errcode = '23514';
        end if;
    elsif tg_table_name = 'product_catalog' and new.category_id is not null then
        select c.space_id into v_ref_space from moneytrack.category_catalog c where c.id = new.category_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_PRODUCT_CATEGORY_CROSS_SPACE' using errcode = '23514';
        end if;
    elsif tg_table_name = 'budget_rules' and new.category_id is not null then
        select c.space_id into v_ref_space from moneytrack.category_catalog c where c.id = new.category_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_BUDGET_CATEGORY_CROSS_SPACE' using errcode = '23514';
        end if;
    elsif tg_table_name = 'space_default_accounts' then
        select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_DEFAULT_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;
    elsif tg_table_name = 'space_financial_settings' then
        if new.default_expense_account_id is not null then
            select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.default_expense_account_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_DEFAULT_EXPENSE_ACCOUNT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;
        if new.default_income_account_id is not null then
            select a.space_id into v_ref_space from moneytrack.accounts a where a.id = new.default_income_account_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_DEFAULT_INCOME_ACCOUNT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;
    elsif tg_table_name = 'receipt_items' then
        select r.space_id into v_receipt_space from moneytrack.receipts r where r.id = new.receipt_id;
        if new.category_id is not null then
            select c.space_id into v_ref_space from moneytrack.category_catalog c where c.id = new.category_id;
            if v_ref_space is distinct from v_receipt_space then
                raise exception 'SPC001_RECEIPT_ITEM_CATEGORY_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;
        if new.product_id is not null then
            select p.space_id into v_ref_space from moneytrack.product_catalog p where p.id = new.product_id;
            if v_ref_space is distinct from v_receipt_space then
                raise exception 'SPC001_RECEIPT_ITEM_PRODUCT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;
    end if;

    return new;
end;
$function$;

-- Re-create triggers idempotently.
do $triggers$
declare
    v_table text;
begin
    foreach v_table in array array[
        'accounts','transactions','transfers','receipts','receipt_items',
        'product_catalog','budget_rules','space_default_accounts','space_financial_settings'
    ] loop
        execute format('drop trigger if exists trg_spc001_same_space on moneytrack.%I', v_table);
        execute format(
            'create trigger trg_spc001_same_space before insert or update on moneytrack.%I for each row execute function moneytrack.spc001_assert_same_space_row_v1()',
            v_table
        );
    end loop;

    -- category_catalog requires only the global/template-vs-Space ownership check.
    execute 'drop trigger if exists trg_spc001_same_space on moneytrack.category_catalog';
    execute 'create trigger trg_spc001_same_space before insert or update on moneytrack.category_catalog for each row execute function moneytrack.spc001_assert_same_space_row_v1()';
end;
$triggers$;

-- Filter presets reference arrays, so validate them separately.
create or replace function moneytrack.spc001_assert_filter_preset_space_v1()
returns trigger
language plpgsql
as $function$
begin
    if new.space_id is null then
        raise exception 'SPC001_FILTER_PRESET_SPACE_REQUIRED' using errcode = '23514';
    end if;

    perform moneytrack.assert_space_member_v1(new.user_id, new.space_id);

    if exists (
        select 1 from unnest(coalesce(new.account_ids, '{}'::bigint[])) x(id)
        where not exists (
            select 1 from moneytrack.accounts a
            where a.id = x.id and a.space_id = new.space_id and coalesce(a.is_active, true) = true
        )
    ) then
        raise exception 'SPC001_FILTER_PRESET_ACCOUNT_CROSS_SPACE' using errcode = '23514';
    end if;

    if exists (
        select 1
        from unnest(coalesce(new.income_category_ids, '{}'::bigint[]) || coalesce(new.expense_category_ids, '{}'::bigint[])) x(id)
        where not exists (
            select 1 from moneytrack.category_catalog c
            where c.id = x.id and c.space_id = new.space_id and coalesce(c.is_active, true) = true
        )
    ) then
        raise exception 'SPC001_FILTER_PRESET_CATEGORY_CROSS_SPACE' using errcode = '23514';
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_spc001_filter_preset_space on moneytrack.filter_presets;
create trigger trg_spc001_filter_preset_space
before insert or update on moneytrack.filter_presets
for each row execute function moneytrack.spc001_assert_filter_preset_space_v1();

-- ---------------------------------------------------------------------------
-- 8. Explicit semantics comments: legacy user_id is NOT the tenant boundary.
-- ---------------------------------------------------------------------------

comment on column moneytrack.accounts.space_id is 'SPC-001 canonical financial tenant. accounts.user_id is legacy compatibility/actor provenance after SPC cutover.';
comment on column moneytrack.transactions.space_id is 'SPC-001 canonical financial tenant. created_by_user_id preserves original author independently of Space ownership.';
comment on column moneytrack.transfers.space_id is 'SPC-001 canonical financial tenant. Both transfer accounts must belong to this Space.';
comment on column moneytrack.receipts.space_id is 'SPC-001A transitional projection ownership. Capture/source split is completed in SPC-001C.';
comment on column moneytrack.category_catalog.space_id is 'SPC-001 Space-owned category instance; NULL only for global/template rows.';
comment on column moneytrack.product_catalog.space_id is 'SPC-001 Space-owned product/classification instance.';
comment on column moneytrack.budget_rules.space_id is 'SPC-001 Space-owned budget rule.';
comment on column moneytrack.filter_presets.space_id is 'SPC-001 user+Space preference context; user_id remains the preference owner.';

commit;
