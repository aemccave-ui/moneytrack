-- MoneyTrack — BE-DOM-001 — hard parity assertions
--
-- This file is intentionally read-only. Unlike 002_verify_finance_read_models.sql,
-- which prints diagnostics, this file raises a psql error on any parity mismatch.
-- It is the machine gate used before n8n cutover.

begin transaction read only;

\if :{?user_id}
\else
  \error 'Required psql variable user_id is missing'
\endif

\if :{?as_of}
\else
  \error 'Required psql variable as_of is missing'
\endif

-- PostgreSQL functions must exist before parity can be evaluated.
do $$
begin
  if to_regprocedure('moneytrack.finance_fx_convert_usd_bridge_v1(numeric,text,text,date)') is null then
    raise exception 'BE-DOM-001 assertion failed: FX function is missing';
  end if;
  if to_regprocedure('moneytrack.finance_accounts_read_model_v1(bigint)') is null then
    raise exception 'BE-DOM-001 assertion failed: accounts read-model function is missing';
  end if;
  if to_regprocedure('moneytrack.finance_dashboard_read_model_v1(bigint,date)') is null then
    raise exception 'BE-DOM-001 assertion failed: dashboard read-model function is missing';
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- FX parity
-- ---------------------------------------------------------------------------

with user_tx as (
    select
        t.id,
        t.amount_original,
        t.currency_original,
        coalesce(s.report_currency, s.base_currency, u.default_currency, 'EUR') as report_currency,
        t.transaction_date::date as rate_date
    from moneytrack.transactions t
    join moneytrack.app_users u on u.id = t.user_id
    left join moneytrack.user_settings s on s.user_id = u.id
    where u.id = :user_id::bigint
),
comparison as (
    select
        tx.id,
        case
            when rf.usd_rate is not null
             and rt.usd_rate is not null
             and rf.usd_rate <> 0
            then tx.amount_original * rt.usd_rate / rf.usd_rate
            else null
        end as legacy_amount,
        moneytrack.finance_fx_convert_usd_bridge_v1(
            tx.amount_original,
            tx.currency_original,
            tx.report_currency,
            tx.rate_date
        ) as extracted_amount
    from user_tx tx
    left join lateral (
        select r.usd_rate
        from moneytrack.exchange_rates_usd r
        where r.currency_code = tx.currency_original
          and r.rate_date <= tx.rate_date
        order by r.rate_date desc
        limit 1
    ) rf on true
    left join lateral (
        select r.usd_rate
        from moneytrack.exchange_rates_usd r
        where r.currency_code = tx.report_currency
          and r.rate_date <= tx.rate_date
        order by r.rate_date desc
        limit 1
    ) rt on true
)
select not exists (
    select 1 from comparison
    where legacy_amount is distinct from extracted_amount
) as fx_parity
\gset

\if :fx_parity
\else
  \error 'BE-DOM-001 assertion failed: FX parity mismatch'
\endif

-- ---------------------------------------------------------------------------
-- Accounts read-model parity
-- ---------------------------------------------------------------------------

with user_ctx as (
    select
        u.id as user_id,
        coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency
    from moneytrack.app_users u
    left join moneytrack.user_settings s on s.user_id = u.id
    where u.id = :user_id::bigint
    limit 1
),
legacy_account_balances as (
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
    join user_ctx uc on uc.user_id = a.user_id
    left join moneytrack.transactions t
      on t.account_id = a.id
     and t.user_id = a.user_id
    where a.is_active = true
    group by
        a.id, a.user_id, a.code, a.name, a.account_type,
        a.currency_code, a.parent_id, a.sort_order, a.is_active
),
legacy_default_account as (
    select jsonb_build_object(
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
      on uda.user_id = uc.user_id
     and uda.currency_code = uc.base_currency
    join legacy_account_balances ab on ab.id = uda.account_id
    limit 1
),
legacy as (
    select
        uc.user_id::bigint as user_id,
        uc.base_currency,
        coalesce(sum(ab.balance_base), 0) as total_base,
        coalesce((select account from legacy_default_account), 'null'::jsonb) as default_account,
        coalesce(
            jsonb_agg(
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
            ) filter (where ab.id is not null),
            '[]'::jsonb
        ) as accounts
    from user_ctx uc
    left join legacy_account_balances ab on true
    group by uc.user_id, uc.base_currency
),
extracted as (
    select * from moneytrack.finance_accounts_read_model_v1(:user_id::bigint)
),
comparison as (
    select
        legacy.user_id = extracted.user_id
        and legacy.base_currency = extracted.base_currency
        and legacy.total_base is not distinct from extracted.total_base
        and legacy.default_account = extracted.default_account
        and legacy.accounts = extracted.accounts as parity
    from legacy
    cross join extracted
)
select coalesce((select parity from comparison), false) as accounts_parity
\gset

\if :accounts_parity
\else
  \error 'BE-DOM-001 assertion failed: accounts read-model parity mismatch'
\endif

-- ---------------------------------------------------------------------------
-- Dashboard summary + latest operations parity
-- ---------------------------------------------------------------------------

with user_ctx as (
    select
        u.id as user_id,
        coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency,
        coalesce(s.report_currency, s.base_currency, u.default_currency, 'EUR')::text as report_currency,
        coalesce(s.language_code, u.language_code, 'en')::text as language_code
    from moneytrack.app_users u
    left join moneytrack.user_settings s on s.user_id = u.id
    where u.id = :user_id::bigint
    limit 1
),
period_ctx as (
    select
        date_trunc('month', :as_of::date)::date as date_from,
        (date_trunc('month', :as_of::date) + interval '1 month - 1 day')::date as date_to
),
tx_with_rates as (
    select
        t.*,
        uc.report_currency,
        case
            when rf.usd_rate is not null
             and rt.usd_rate is not null
             and rf.usd_rate <> 0
            then t.amount_original * rt.usd_rate / rf.usd_rate
            else null
        end as amount_report
    from moneytrack.transactions t
    join user_ctx uc on uc.user_id = t.user_id
    left join lateral (
        select r.usd_rate
        from moneytrack.exchange_rates_usd r
        where r.currency_code = t.currency_original
          and r.rate_date <= t.transaction_date::date
        order by r.rate_date desc
        limit 1
    ) rf on true
    left join lateral (
        select r.usd_rate
        from moneytrack.exchange_rates_usd r
        where r.currency_code = uc.report_currency
          and r.rate_date <= t.transaction_date::date
        order by r.rate_date desc
        limit 1
    ) rt on true
),
month_summary as (
    select
        coalesce(sum(case when transaction_type = 'income' then amount_report else 0 end), 0) as income_month,
        coalesce(sum(case when transaction_type = 'expense' then abs(amount_report) else 0 end), 0) as expenses_month
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
    join user_ctx uc on uc.user_id = a.user_id
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
        case
            when rf.usd_rate is not null
             and rt.usd_rate is not null
             and rf.usd_rate <> 0
            then ab.balance * rt.usd_rate / rf.usd_rate
            else null
        end as balance_report
    from account_balances ab
    cross join user_ctx uc
    left join lateral (
        select r.usd_rate
        from moneytrack.exchange_rates_usd r
        where r.currency_code = ab.currency_code
          and r.rate_date <= :as_of::date
        order by r.rate_date desc
        limit 1
    ) rf on true
    left join lateral (
        select r.usd_rate
        from moneytrack.exchange_rates_usd r
        where r.currency_code = uc.report_currency
          and r.rate_date <= :as_of::date
        order by r.rate_date desc
        limit 1
    ) rt on true
),
legacy_latest as (
    select coalesce(
        jsonb_agg(
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
        ),
        '[]'::jsonb
    ) as latest_operations
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
        left join moneytrack.accounts a on a.id = t.account_id
        where t.user_id = :user_id::bigint
        order by t.transaction_date desc, t.id desc
        limit 10
    ) x
),
legacy as (
    select
        pc.date_from,
        pc.date_to,
        coalesce((select sum(balance_report) from account_balances_report), 0) as net_worth,
        ms.income_month,
        ms.expenses_month,
        ms.income_month - ms.expenses_month as result_month,
        coalesce(
            (
                select jsonb_agg(
                    jsonb_build_object('currency', ab.currency_code, 'balance', ab.balance)
                    order by ab.currency_code
                )
                from account_balances ab
            ),
            '[]'::jsonb
        ) as balances_by_currency,
        ll.latest_operations
    from user_ctx uc
    cross join period_ctx pc
    cross join month_summary ms
    cross join legacy_latest ll
),
extracted as (
    select *
    from moneytrack.finance_dashboard_read_model_v1(:user_id::bigint, :as_of::date)
),
comparison as (
    select
        legacy.date_from = extracted.date_from
        and legacy.date_to = extracted.date_to
        and legacy.net_worth is not distinct from extracted.net_worth
        and legacy.income_month is not distinct from extracted.income_month
        and legacy.expenses_month is not distinct from extracted.expenses_month
        and legacy.result_month is not distinct from extracted.result_month
        and legacy.balances_by_currency = extracted.balances_by_currency
        and legacy.latest_operations = extracted.latest_operations as parity
    from legacy
    cross join extracted
)
select coalesce((select parity from comparison), false) as dashboard_parity
\gset

\if :dashboard_parity
\else
  \error 'BE-DOM-001 assertion failed: dashboard read-model parity mismatch'
\endif

rollback;
