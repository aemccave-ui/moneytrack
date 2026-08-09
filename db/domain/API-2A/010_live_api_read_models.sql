-- MoneyTrack — API-2A — Live API Read Models
--
-- Compatibility-first extraction of the three live complex MiniApp read paths
-- identified by API-1. Request validation, Telegram InitData verification and
-- response formatting remain adapter concerns in API-2A.
--
-- Extracted paths:
--   GET /api/v1/transactions
--   GET /api/v1/accounts-explorer-summary
--   GET /api/v1/transaction-reference
--
-- IMPORTANT: preserve current production semantics; do not redesign contracts.

begin;

-- ---------------------------------------------------------------------------
-- Transactions API read model
-- ---------------------------------------------------------------------------

create or replace function moneytrack.api_transactions_read_model_v1(
    p_telegram_user_id bigint,
    p_account_id text,
    p_date_from date,
    p_date_to date,
    p_include_descendants boolean
)
returns table (
    user_id bigint,
    base_currency text,
    account_id text,
    date_from date,
    date_to date,
    include_descendants boolean,
    account_scope_count bigint,
    income numeric,
    expense numeric,
    result numeric,
    transfers numeric,
    count bigint,
    missing_rate_count bigint,
    summary_currency text,
    transactions jsonb
)
language sql
stable
as $function$
    with recursive
    user_ctx as (
        select
            u.id as internal_user_id,
            coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency
        from moneytrack.app_users u
        left join moneytrack.user_settings s
          on s.user_id = u.id
        where u.telegram_user_id = p_telegram_user_id
        limit 1
    ),
    requested_account as (
        select a.id, a.currency_code
        from moneytrack.accounts a
        join user_ctx uc
          on uc.internal_user_id = a.user_id
        where a.id::text = p_account_id
          and a.is_active = true
        limit 1
    ),
    scope_accounts as (
        select ra.id
        from requested_account ra

        union all

        select child.id
        from moneytrack.accounts child
        join scope_accounts parent
          on child.parent_id = parent.id
        join user_ctx uc
          on uc.internal_user_id = child.user_id
        where child.is_active = true
          and p_include_descendants
    ),
    filtered_transactions as (
        select
            t.id,
            t.transaction_type,
            t.account_id,
            a.name as account_name,
            t.amount_original,
            coalesce(
                nullif(t.currency_original, ''),
                a.currency_code,
                uc.base_currency
            )::text as currency_original,
            t.category_id,
            t.description,
            t.transaction_date,
            uc.base_currency
        from moneytrack.transactions t
        join user_ctx uc
          on uc.internal_user_id = t.user_id
        join scope_accounts sa
          on sa.id = t.account_id
        left join moneytrack.accounts a
          on a.id = t.account_id
         and a.user_id = t.user_id
        where t.transaction_date >= p_date_from
          and t.transaction_date < (p_date_to + 1)::date
    ),
    converted_transactions as (
        select
            ft.*,
            case
                when ft.currency_original = ft.base_currency
                    then abs(coalesce(ft.amount_original, 0))
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    abs(coalesce(ft.amount_original, 0)),
                    ft.currency_original,
                    ft.base_currency,
                    ft.transaction_date::date
                )
            end as amount_base_effective
        from filtered_transactions ft
    ),
    summary as (
        select
            coalesce(sum(
                case when transaction_type = 'income'
                     then amount_base_effective else 0 end
            ), 0) as income,
            coalesce(sum(
                case when transaction_type = 'expense'
                     then amount_base_effective else 0 end
            ), 0) as expense,
            coalesce(sum(
                case when transaction_type = 'income'
                     then abs(coalesce(amount_original, 0)) else 0 end
            ), 0) as income_original,
            coalesce(sum(
                case when transaction_type = 'expense'
                     then abs(coalesce(amount_original, 0)) else 0 end
            ), 0) as expense_original,
            coalesce(sum(
                case when transaction_type = 'income'
                     then amount_base_effective else 0 end
            ), 0)
            -
            coalesce(sum(
                case when transaction_type = 'expense'
                     then amount_base_effective else 0 end
            ), 0) as result,
            coalesce(sum(
                case when transaction_type = 'transfer'
                     then amount_base_effective else 0 end
            ), 0) as transfers,
            count(*)::bigint as tx_count,
            count(*) filter (
                where amount_base_effective is null
            )::bigint as missing_rate_count
        from converted_transactions
    ),
    items as (
        select coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'id', x.id,
                    'transaction_type', x.transaction_type,
                    'account_id', x.account_id,
                    'account_name', x.account_name,
                    'amount_original', x.amount_original,
                    'amount_base', x.amount_base_effective,
                    'currency_original', x.currency_original,
                    'category_id', x.category_id,
                    'description', x.description,
                    'transaction_date', x.transaction_date
                )
                order by x.transaction_date desc, x.id desc
            ),
            '[]'::jsonb
        ) as transactions
        from converted_transactions x
    )
    select
        uc.internal_user_id::bigint as user_id,
        uc.base_currency,
        p_account_id::text as account_id,
        p_date_from as date_from,
        p_date_to as date_to,
        p_include_descendants as include_descendants,
        (select count(*) from scope_accounts)::bigint as account_scope_count,
        case
            when (select count(*) from scope_accounts) = 1
            then s.income_original
            else s.income
        end as income,
        case
            when (select count(*) from scope_accounts) = 1
            then s.expense_original
            else s.expense
        end as expense,
        case
            when (select count(*) from scope_accounts) = 1
            then s.income_original - s.expense_original
            else s.result
        end as result,
        s.transfers,
        s.tx_count as count,
        s.missing_rate_count,
        case
            when (select count(*) from scope_accounts) = 1
            then (select ra.currency_code from requested_account ra limit 1)
            else uc.base_currency
        end::text as summary_currency,
        i.transactions
    from user_ctx uc
    cross join summary s
    cross join items i;
$function$;

comment on function moneytrack.api_transactions_read_model_v1(bigint, text, date, date, boolean)
is 'API-2A compatibility read model for GET /api/v1/transactions. Preserves ownership, descendants, period, FX, leaf-summary-currency and JSON item semantics.';

-- ---------------------------------------------------------------------------
-- Accounts Explorer Summary API read model
-- ---------------------------------------------------------------------------

create or replace function moneytrack.api_accounts_explorer_summary_read_model_v1(
    p_telegram_user_id bigint,
    p_excluded_account_ids bigint[],
    p_date_from date,
    p_date_to date,
    p_as_of date
)
returns table (
    user_id bigint,
    base_currency text,
    total_base numeric,
    included_account_count bigint,
    period_income numeric,
    period_expense numeric,
    period_result numeric,
    missing_rate_count bigint,
    date_from date,
    date_to date
)
language sql
stable
as $function$
    with recursive
    user_ctx as (
        select
            u.id as internal_user_id,
            coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency
        from moneytrack.app_users u
        left join moneytrack.user_settings s
          on s.user_id = u.id
        where u.telegram_user_id = p_telegram_user_id
        limit 1
    ),
    excluded as (
        select unnest(coalesce(p_excluded_account_ids, '{}'::bigint[])) as id
    ),
    active_leaf_accounts as (
        select a.id
        from moneytrack.accounts a
        join user_ctx uc
          on uc.internal_user_id = a.user_id
        where a.is_active = true
          and not exists (
              select 1
              from moneytrack.accounts c
              where c.user_id = a.user_id
                and c.parent_id = a.id
                and c.is_active = true
          )
          and not exists (
              select 1 from excluded e where e.id = a.id
          )
    ),
    active_accounts(id) as (
        select id from active_leaf_accounts

        union

        select parent.id
        from active_accounts aa
        join moneytrack.accounts child
          on child.id = aa.id
        join moneytrack.accounts parent
          on parent.id = child.parent_id
         and parent.user_id = child.user_id
        join user_ctx uc
          on uc.internal_user_id = parent.user_id
        where parent.is_active = true
    ),
    transaction_movements as (
        select
            t.account_id,
            case
                when t.transaction_type in ('openingbalance', 'income')
                    then t.amount_original
                when t.transaction_type = 'expense'
                    then -t.amount_original
                when t.transaction_type = 'adjustment'
                    then t.amount_original
                else 0
            end as amount
        from moneytrack.transactions t
        join user_ctx uc
          on uc.internal_user_id = t.user_id
    ),
    transfer_movements as (
        select tr.from_account_id as account_id, -tr.from_amount as amount
        from moneytrack.transfers tr
        join user_ctx uc
          on uc.internal_user_id = tr.user_id

        union all

        select tr.to_account_id as account_id, tr.to_amount as amount
        from moneytrack.transfers tr
        join user_ctx uc
          on uc.internal_user_id = tr.user_id
    ),
    movements as (
        select * from transaction_movements
        union all
        select * from transfer_movements
    ),
    raw_balances as (
        select
            a.id,
            a.currency_code,
            coalesce(sum(m.amount), 0) as balance_original
        from moneytrack.accounts a
        join user_ctx uc
          on uc.internal_user_id = a.user_id
        join active_accounts aa
          on aa.id = a.id
        left join movements m
          on m.account_id = a.id
        where a.is_active = true
        group by a.id, a.currency_code
    ),
    converted_balances as (
        select
            rb.id,
            case
                when rb.currency_code = uc.base_currency
                    then rb.balance_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    rb.balance_original,
                    rb.currency_code,
                    uc.base_currency,
                    p_as_of
                )
            end as balance_base
        from raw_balances rb
        cross join user_ctx uc
    ),
    period_transactions as (
        select
            t.transaction_type,
            abs(coalesce(t.amount_original, 0)) as amount_original,
            coalesce(
                nullif(t.currency_original, ''),
                a.currency_code,
                uc.base_currency
            )::text as source_currency,
            uc.base_currency,
            t.transaction_date
        from moneytrack.transactions t
        join user_ctx uc
          on uc.internal_user_id = t.user_id
        join active_accounts aa
          on aa.id = t.account_id
        left join moneytrack.accounts a
          on a.id = t.account_id
         and a.user_id = t.user_id
        where t.transaction_date >= p_date_from
          and t.transaction_date < (p_date_to + 1)::date
    ),
    converted_period_transactions as (
        select
            pt.transaction_type,
            case
                when pt.source_currency = pt.base_currency
                    then pt.amount_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    pt.amount_original,
                    pt.source_currency,
                    pt.base_currency,
                    pt.transaction_date::date
                )
            end as amount_base_effective
        from period_transactions pt
    ),
    period_summary as (
        select
            coalesce(sum(
                case when transaction_type = 'income'
                     then amount_base_effective else 0 end
            ), 0) as income,
            coalesce(sum(
                case when transaction_type = 'expense'
                     then amount_base_effective else 0 end
            ), 0) as expense,
            count(*) filter (
                where amount_base_effective is null
            )::bigint as missing_rate_count
        from converted_period_transactions
    )
    select
        uc.internal_user_id::bigint as user_id,
        uc.base_currency,
        coalesce((select sum(cb.balance_base) from converted_balances cb), 0) as total_base,
        (select count(*) from active_accounts)::bigint as included_account_count,
        ps.income as period_income,
        ps.expense as period_expense,
        ps.income - ps.expense as period_result,
        ps.missing_rate_count,
        p_date_from as date_from,
        p_date_to as date_to
    from user_ctx uc
    cross join period_summary ps;
$function$;

comment on function moneytrack.api_accounts_explorer_summary_read_model_v1(bigint, bigint[], date, date, date)
is 'API-2A compatibility read model for GET /api/v1/accounts-explorer-summary. Preserves leaf exclusion, ancestor inclusion, movement balances, FX and period summary semantics.';

-- ---------------------------------------------------------------------------
-- Transaction Reference API read model
-- ---------------------------------------------------------------------------

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
        select t.currency_original as code, count(*)::bigint as usage_count
        from moneytrack.transactions t
        join user_ctx u
          on u.internal_user_id = t.user_id
        group by t.currency_original
    ),
    currency_rows as (
        select c.code, coalesce(cu.usage_count, 0)::bigint as usage_count
        from moneytrack.currencies c
        left join currency_usage cu
          on cu.code = c.code
        where coalesce(c.is_active, true) = true
    ),
    category_rows as (
        select
            c.id,
            c.code,
            coalesce(
                nullif(to_jsonb(c)->>'parent_id', '')::bigint,
                nullif(to_jsonb(c)->>'parent_category_id', '')::bigint
            ) as parent_id,
            coalesce(nullif(to_jsonb(c)->>'sort_order', '')::int, 0) as sort_order,
            coalesce(t_user.name, t_en.name, c.code) as name
        from moneytrack.category_catalog c
        cross join user_ctx u
        left join moneytrack.category_catalog_translations t_user
          on t_user.category_id = c.id
         and t_user.language_code = u.language_code
        left join moneytrack.category_catalog_translations t_en
          on t_en.category_id = c.id
         and t_en.language_code = 'en'
        where c.is_active = true
          and (c.user_id = u.internal_user_id or c.user_id = 0)
    )
    select
        exists(select 1 from user_ctx) as user_found,
        coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'code', cr.code,
                    'usage_count', cr.usage_count
                )
                order by (cr.usage_count > 0) desc, cr.code asc
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
                    'sort_order', cr.sort_order
                )
                order by cr.sort_order, cr.name
            )
            from category_rows cr
        ), '[]'::jsonb) as categories;
$function$;

comment on function moneytrack.api_transaction_reference_read_model_v1(bigint)
is 'API-2A compatibility read model for GET /api/v1/transaction-reference. Preserves active currency ordering/usage and user/global localized category semantics.';

commit;
