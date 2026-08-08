-- MoneyTrack — BE-DOM-001 — Finance Domain Extraction
--
-- Purpose:
--   Extract the existing finance read semantics from n8n into versioned,
--   independently callable PostgreSQL entry points.
--
-- IMPORTANT:
--   This migration is intentionally compatibility-first. It reproduces the
--   current MiniApp API financial semantics; it does not silently correct or
--   redesign them.
--
-- Caller identity (Telegram -> internal user_id) remains an adapter concern.

begin;

-- ---------------------------------------------------------------------------
-- Canonical compatibility FX conversion
-- ---------------------------------------------------------------------------
--
-- Reproduces the formula currently embedded in the MiniApp dashboard workflow:
--
--   amount_to = amount_from * to.usd_rate / from.usd_rate
--
-- using the latest rate on or before p_rate_date for each currency.
--
-- Missing-rate behavior is deliberately preserved: NULL is returned when one
-- of the required rates is absent or the source rate is zero.
--
-- Do not change the orientation of usd_rate here without a separate finance
-- migration that validates the semantic meaning of exchange_rates_usd.usd_rate.

create or replace function moneytrack.finance_fx_convert_usd_bridge_v1(
    p_amount numeric,
    p_from_currency text,
    p_to_currency text,
    p_rate_date date
)
returns numeric
language sql
stable
as $function$
    with rates as (
        select
            (
                select r.usd_rate
                from moneytrack.exchange_rates_usd r
                where r.currency_code = p_from_currency
                  and r.rate_date <= p_rate_date
                order by r.rate_date desc
                limit 1
            ) as from_usd_rate,
            (
                select r.usd_rate
                from moneytrack.exchange_rates_usd r
                where r.currency_code = p_to_currency
                  and r.rate_date <= p_rate_date
                order by r.rate_date desc
                limit 1
            ) as to_usd_rate
    )
    select
        case
            when rates.from_usd_rate is not null
             and rates.to_usd_rate is not null
             and rates.from_usd_rate <> 0
            then p_amount * rates.to_usd_rate / rates.from_usd_rate
            else null
        end
    from rates;
$function$;

comment on function moneytrack.finance_fx_convert_usd_bridge_v1(numeric, text, text, date)
is 'BE-DOM-001 compatibility FX rule. Latest rates <= valuation date; preserves legacy USD-bridge formula and NULL-on-missing-rate behavior.';

-- ---------------------------------------------------------------------------
-- Accounts read model
-- ---------------------------------------------------------------------------
--
-- This function moves the financial calculation out of n8n while preserving
-- the existing intermediate row contract consumed by the current response
-- formatter:
--
--   user_id
--   base_currency
--   total_base
--   default_account
--   accounts   (flat JSON array; adapter may build the display tree)
--
-- Existing semantics intentionally preserved:
--   balance_original = SUM(transactions.amount_original)
--   balance_base     = SUM(transactions.amount_base)
--   active accounts only
--   default account selected for base currency

create or replace function moneytrack.finance_accounts_read_model_v1(
    p_user_id bigint
)
returns table (
    user_id bigint,
    base_currency text,
    total_base numeric,
    default_account jsonb,
    accounts jsonb
)
language sql
stable
as $function$
    with user_ctx as (
        select
            u.id as internal_user_id,
            coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency
        from moneytrack.app_users u
        left join moneytrack.user_settings s
               on s.user_id = u.id
        where u.id = p_user_id
        limit 1
    ),
    account_balances as (
        select
            a.id,
            a.user_id,
            a.code,
            a.name,
            a.account_type,
            a.currency_code,
            a.parent_id,
            a.sort_order,
            a.is_active,
            coalesce(sum(t.amount_original), 0) as balance_original,
            coalesce(sum(t.amount_base), 0) as balance_base
        from moneytrack.accounts a
        join user_ctx uc
          on uc.internal_user_id = a.user_id
        left join moneytrack.transactions t
          on t.account_id = a.id
         and t.user_id = a.user_id
        where a.is_active = true
        group by
            a.id,
            a.user_id,
            a.code,
            a.name,
            a.account_type,
            a.currency_code,
            a.parent_id,
            a.sort_order,
            a.is_active
    ),
    default_account as (
        select
            jsonb_build_object(
                'account_id', ab.id,
                'code', ab.code,
                'name', ab.name,
                'account_name', ab.name,
                'account_type', ab.account_type,
                'currency_code', ab.currency_code,
                'balance_original', ab.balance_original,
                'balance_base', ab.balance_base
            ) as account
        from user_ctx uc
        join moneytrack.user_default_accounts uda
          on uda.user_id = uc.internal_user_id
         and uda.currency_code = uc.base_currency
        join account_balances ab
          on ab.id = uda.account_id
        limit 1
    ),
    accounts_json as (
        select jsonb_agg(
            jsonb_build_object(
                'id', ab.id,
                'code', ab.code,
                'name', ab.name,
                'account_type', ab.account_type,
                'currency_code', ab.currency_code,
                'parent_id', ab.parent_id,
                'sort_order', ab.sort_order,
                'balance_original', ab.balance_original,
                'balance_base', ab.balance_base
            )
            order by
                coalesce(ab.parent_id, ab.id),
                ab.parent_id nulls first,
                ab.sort_order,
                ab.name
        ) as accounts
        from account_balances ab
    ),
    total_base as (
        select coalesce(sum(ab.balance_base), 0) as total_base
        from account_balances ab
    )
    select
        uc.internal_user_id::bigint as user_id,
        uc.base_currency,
        tb.total_base,
        coalesce(
            (select da.account from default_account da),
            'null'::jsonb
        ) as default_account,
        coalesce(aj.accounts, '[]'::jsonb) as accounts
    from user_ctx uc
    cross join total_base tb
    cross join accounts_json aj;
$function$;

comment on function moneytrack.finance_accounts_read_model_v1(bigint)
is 'BE-DOM-001 accounts read model. Preserves legacy active-account balance_original/balance_base aggregation and base-currency default-account selection.';

-- ---------------------------------------------------------------------------
-- Dashboard read model
-- ---------------------------------------------------------------------------
--
-- p_as_of is explicit by design. Runtime adapters should pass CURRENT_DATE when
-- they want the legacy "today" behavior. Tests/backends can pass a fixed date.
--
-- Existing semantics intentionally preserved:
--   - calendar month containing p_as_of;
--   - transaction-date FX for monthly income/expense;
--   - p_as_of-date FX for net worth;
--   - income uses transaction_type = 'income';
--   - expense uses transaction_type = 'expense' and ABS(converted amount);
--   - net-worth balance aggregation does NOT add an as-of transaction filter;
--   - latest operations are latest 10 overall, not month-limited;
--   - missing FX conversion remains NULL and aggregate SUM keeps PostgreSQL's
--     legacy null-handling behavior.

create or replace function moneytrack.finance_dashboard_read_model_v1(
    p_user_id bigint,
    p_as_of date
)
returns table (
    user_id bigint,
    base_currency text,
    report_currency text,
    language_code text,
    date_from date,
    date_to date,
    net_worth numeric,
    income_month numeric,
    expenses_month numeric,
    result_month numeric,
    balances_by_currency jsonb,
    latest_operations jsonb
)
language sql
stable
as $function$
    with user_ctx as (
        select
            u.id as internal_user_id,
            coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency,
            coalesce(s.report_currency, s.base_currency, u.default_currency, 'EUR')::text as report_currency,
            coalesce(s.language_code, u.language_code, 'en')::text as language_code
        from moneytrack.app_users u
        left join moneytrack.user_settings s
               on s.user_id = u.id
        where u.id = p_user_id
        limit 1
    ),
    period_ctx as (
        select
            date_trunc('month', p_as_of)::date as date_from,
            (date_trunc('month', p_as_of) + interval '1 month - 1 day')::date as date_to
    ),
    tx_with_rates as (
        select
            t.*,
            uc.report_currency,
            moneytrack.finance_fx_convert_usd_bridge_v1(
                t.amount_original,
                t.currency_original,
                uc.report_currency,
                t.transaction_date::date
            ) as amount_report
        from moneytrack.transactions t
        join user_ctx uc
          on uc.internal_user_id = t.user_id
    ),
    month_summary as (
        select
            coalesce(sum(
                case
                    when t.transaction_type = 'income'
                    then t.amount_report
                    else 0
                end
            ), 0) as income_month,
            coalesce(sum(
                case
                    when t.transaction_type = 'expense'
                    then abs(t.amount_report)
                    else 0
                end
            ), 0) as expenses_month
        from tx_with_rates t
        join period_ctx pc on true
        where t.transaction_date >= pc.date_from
          and t.transaction_date < pc.date_to + interval '1 day'
    ),
    account_balances as (
        select
            a.currency_code,
            coalesce(sum(t.amount_original), 0) as balance
        from moneytrack.accounts a
        join user_ctx uc
          on uc.internal_user_id = a.user_id
        left join moneytrack.transactions t
               on t.account_id = a.id
              and t.user_id = a.user_id
        where a.is_active = true
        group by a.currency_code
    ),
    account_balances_report as (
        select
            ab.currency_code,
            ab.balance,
            moneytrack.finance_fx_convert_usd_bridge_v1(
                ab.balance,
                ab.currency_code,
                uc.report_currency,
                p_as_of
            ) as balance_report
        from account_balances ab
        cross join user_ctx uc
    ),
    networth as (
        select coalesce(sum(abr.balance_report), 0) as net_worth
        from account_balances_report abr
    ),
    latest_operations as (
        select jsonb_agg(
            jsonb_build_object(
                'id', x.id,
                'transaction_type', x.transaction_type,
                'account_id', x.account_id,
                'account_name', x.account_name,
                'amount_original', x.amount_original,
                'currency_original', x.currency_original,
                'category_id', x.category_id,
                'description', x.description,
                'transaction_date', x.transaction_date
            )
            order by x.transaction_date desc, x.id desc
        ) as items
        from (
            select
                t.id,
                t.transaction_type,
                t.account_id,
                a.name as account_name,
                t.amount_original,
                t.currency_original,
                t.category_id,
                t.description,
                t.transaction_date
            from moneytrack.transactions t
            join user_ctx uc
              on uc.internal_user_id = t.user_id
            left join moneytrack.accounts a
              on a.id = t.account_id
            order by t.transaction_date desc, t.id desc
            limit 10
        ) x
    )
    select
        uc.internal_user_id::bigint as user_id,
        uc.base_currency,
        uc.report_currency,
        uc.language_code,
        pc.date_from,
        pc.date_to,
        nw.net_worth,
        ms.income_month,
        ms.expenses_month,
        ms.income_month - ms.expenses_month as result_month,
        coalesce(
            (
                select jsonb_agg(
                    jsonb_build_object(
                        'currency', ab.currency_code,
                        'balance', ab.balance
                    )
                    order by ab.currency_code
                )
                from account_balances ab
            ),
            '[]'::jsonb
        ) as balances_by_currency,
        coalesce(lo.items, '[]'::jsonb) as latest_operations
    from user_ctx uc
    cross join period_ctx pc
    cross join month_summary ms
    cross join networth nw
    cross join latest_operations lo;
$function$;

comment on function moneytrack.finance_dashboard_read_model_v1(bigint, date)
is 'BE-DOM-001 dashboard read model. Explicit as_of date; preserves legacy monthly summary, USD-bridge FX, net-worth and latest-operation semantics.';

commit;
