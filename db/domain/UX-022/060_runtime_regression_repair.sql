-- MoneyTrack — UX-022R3 — runtime regression repair
-- Transfer-inclusive dashboard snapshot aligned with Accounts Explorer semantics.

begin;

create or replace function moneytrack.finance_dashboard_read_model_v2(
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
                case when t.transaction_type = 'income' then t.amount_report else 0 end
            ), 0) as income_month,
            coalesce(sum(
                case when t.transaction_type = 'expense' then abs(t.amount_report) else 0 end
            ), 0) as expenses_month
        from tx_with_rates t
        join period_ctx pc on true
        where t.transaction_date >= pc.date_from
          and t.transaction_date < pc.date_to + interval '1 day'
    ),
    active_accounts as (
        select a.id, a.currency_code
        from moneytrack.accounts a
        join user_ctx uc on uc.internal_user_id = a.user_id
        where coalesce(a.is_active, true) = true
    ),
    transaction_movements as (
        select
            t.account_id,
            case
                when t.transaction_type in ('openingbalance', 'income') then t.amount_original
                when t.transaction_type = 'expense' then -t.amount_original
                when t.transaction_type = 'adjustment' then t.amount_original
                else 0
            end::numeric as amount
        from moneytrack.transactions t
        join user_ctx uc on uc.internal_user_id = t.user_id
        where t.transaction_date < (p_as_of + 1)::date
    ),
    transfer_movements as (
        select tr.from_account_id as account_id, -tr.from_amount::numeric as amount
        from moneytrack.transfers tr
        join user_ctx uc on uc.internal_user_id = tr.user_id
        where tr.transfer_date < (p_as_of + 1)::date
        union all
        select tr.to_account_id as account_id, tr.to_amount::numeric as amount
        from moneytrack.transfers tr
        join user_ctx uc on uc.internal_user_id = tr.user_id
        where tr.transfer_date < (p_as_of + 1)::date
    ),
    movements as (
        select * from transaction_movements
        union all
        select * from transfer_movements
    ),
    own_balances as (
        select
            a.id as account_id,
            a.currency_code,
            coalesce(sum(m.amount), 0)::numeric as balance_original
        from active_accounts a
        left join movements m on m.account_id = a.id
        group by a.id, a.currency_code
    ),
    account_balances as (
        select
            ob.currency_code,
            coalesce(sum(ob.balance_original), 0)::numeric as balance
        from own_balances ob
        group by ob.currency_code
    ),
    account_balances_report as (
        select
            ab.currency_code,
            ab.balance,
            case
                when ab.balance = 0 then 0::numeric
                when upper(ab.currency_code) = upper(uc.report_currency) then ab.balance
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    ab.balance,
                    upper(ab.currency_code),
                    upper(uc.report_currency),
                    p_as_of
                )
            end as balance_report
        from account_balances ab
        cross join user_ctx uc
    ),
    networth as (
        select coalesce(sum(abr.balance_report), 0)::numeric as net_worth
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
            join user_ctx uc on uc.internal_user_id = t.user_id
            left join moneytrack.accounts a on a.id = t.account_id
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
        coalesce((
            select jsonb_agg(
                jsonb_build_object('currency', ab.currency_code, 'balance', ab.balance)
                order by ab.currency_code
            )
            from account_balances ab
        ), '[]'::jsonb) as balances_by_currency,
        coalesce(lo.items, '[]'::jsonb) as latest_operations
    from user_ctx uc
    cross join period_ctx pc
    cross join month_summary ms
    cross join networth nw
    cross join latest_operations lo;
$function$;

comment on function moneytrack.finance_dashboard_read_model_v2(bigint, date)
is 'UX-022R3 dashboard snapshot aligned with Accounts Explorer: signed transaction movements plus transfer movements, valued as of p_as_of; monthly turnover/latest-operation response shape remains compatible with v1.';

commit;
