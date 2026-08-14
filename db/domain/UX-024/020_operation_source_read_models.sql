-- MoneyTrack — UX-024 — expose canonical persisted operation source to MiniApp read models.
-- Depends on 010_operation_source_and_datetime_guard.sql.

begin;

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
        left join moneytrack.user_settings s on s.user_id = u.id
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
        join user_ctx uc on uc.internal_user_id = t.user_id
    ),
    month_summary as (
        select
            coalesce(sum(case when t.transaction_type = 'income' then t.amount_report else 0 end), 0) as income_month,
            coalesce(sum(case when t.transaction_type = 'expense' then abs(t.amount_report) else 0 end), 0) as expenses_month
        from tx_with_rates t
        join period_ctx pc on true
        where t.transaction_date >= pc.date_from
          and t.transaction_date < pc.date_to + interval '1 day'
    ),
    account_balances as (
        select a.currency_code, coalesce(sum(t.amount_original), 0) as balance
        from moneytrack.accounts a
        join user_ctx uc on uc.internal_user_id = a.user_id
        left join moneytrack.transactions t on t.account_id = a.id and t.user_id = a.user_id
        where a.is_active = true
        group by a.currency_code
    ),
    account_balances_report as (
        select
            ab.currency_code,
            ab.balance,
            moneytrack.finance_fx_convert_usd_bridge_v1(ab.balance, ab.currency_code, uc.report_currency, p_as_of) as balance_report
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
                'transaction_date', x.transaction_date,
                'source_kind', x.source_kind
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
                t.transaction_date,
                moneytrack.operation_source_kind_v1(t.user_id, t.id) as source_kind
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

comment on function moneytrack.finance_dashboard_read_model_v1(bigint,date)
is 'UX-024 dashboard read model: preserves existing finance semantics and adds persisted source_kind to latest operation JSON.';

create or replace function moneytrack.api_transactions_read_model_v2(
    p_telegram_user_id bigint,
    p_account_id bigint,
    p_date_from date,
    p_date_to date,
    p_include_descendants boolean,
    p_selected_account_ids bigint[],
    p_income_category_ids bigint[],
    p_expense_category_ids bigint[]
)
returns table (
    user_id bigint,
    base_currency text,
    account_id bigint,
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
language plpgsql
stable
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
begin
    if p_date_from is null or p_date_to is null then raise exception 'DATE_REQUIRED' using errcode = '22023'; end if;
    if p_date_from > p_date_to then raise exception 'DATE_RANGE_INVALID' using errcode = '22023'; end if;

    if not exists (
        select 1 from moneytrack.accounts a
        where a.id = p_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true
    ) then raise exception 'ACCOUNT_NOT_FOUND' using errcode = 'P0002'; end if;

    return query
    with recursive
    user_ctx as (
        select u.id as internal_user_id,
               coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency
        from moneytrack.app_users u
        left join moneytrack.user_settings s on s.user_id = u.id
        where u.id = v_user_id
    ),
    raw_scope as (
        select a.id, a.currency_code
        from moneytrack.accounts a
        where a.id = p_account_id and a.user_id = v_user_id and coalesce(a.is_active, true) = true
        union all
        select child.id, child.currency_code
        from moneytrack.accounts child
        join raw_scope parent on child.parent_id = parent.id
        where child.user_id = v_user_id
          and coalesce(child.is_active, true) = true
          and p_include_descendants
    ),
    scope_accounts as (
        select * from raw_scope s
        where p_selected_account_ids is null or s.id = any(p_selected_account_ids)
    ),
    tx_source as (
        select
            t.id,
            t.transaction_type,
            t.account_id,
            a.name as account_name,
            abs(coalesce(t.amount_original, 0)) as amount_original,
            coalesce(nullif(t.currency_original, ''), a.currency_code, uc.base_currency)::text as source_currency,
            t.category_id,
            t.description,
            t.transaction_date,
            uc.base_currency,
            moneytrack.operation_source_kind_v1(t.user_id, t.id) as source_kind
        from moneytrack.transactions t
        join scope_accounts sa on sa.id = t.account_id
        join moneytrack.accounts a on a.id = t.account_id and a.user_id = t.user_id
        cross join user_ctx uc
        where t.user_id = v_user_id
          and t.transaction_date >= p_date_from
          and t.transaction_date < (p_date_to + 1)::date
          and (
            t.transaction_type not in ('income','expense','adjustment')
            or (t.transaction_type = 'income' and (p_income_category_ids is null or t.category_id = any(p_income_category_ids)))
            or (t.transaction_type in ('expense','adjustment') and (p_expense_category_ids is null or t.category_id = any(p_expense_category_ids)))
          )
    ),
    tx_converted as (
        select s.*,
            case
                when s.amount_original = 0 then 0::numeric
                when upper(s.source_currency) = upper(s.base_currency) then s.amount_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    s.amount_original, upper(s.source_currency), upper(s.base_currency), s.transaction_date::date
                )
            end as amount_base
        from tx_source s
    ),
    transfer_source as (
        select
            tr.id,
            case when sa_from.id is not null then tr.from_account_id else tr.to_account_id end as scoped_account_id,
            case when sa_from.id is not null then a_from.name else a_to.name end as account_name,
            case when sa_from.id is not null then tr.from_amount else tr.to_amount end as amount_original,
            case when sa_from.id is not null then tr.from_currency else tr.to_currency end as source_currency,
            case when sa_from.id is not null then 'outgoing'::text else 'incoming'::text end as transfer_direction,
            coalesce(tr.transfer_type, 'transfer')::text as transfer_type,
            tr.transfer_date,
            uc.base_currency
        from moneytrack.transfers tr
        cross join user_ctx uc
        left join scope_accounts sa_from on sa_from.id = tr.from_account_id
        left join scope_accounts sa_to on sa_to.id = tr.to_account_id
        left join moneytrack.accounts a_from on a_from.id = tr.from_account_id and a_from.user_id = tr.user_id
        left join moneytrack.accounts a_to on a_to.id = tr.to_account_id and a_to.user_id = tr.user_id
        where tr.user_id = v_user_id
          and tr.transfer_date >= p_date_from
          and tr.transfer_date < (p_date_to + 1)::date
          and ((sa_from.id is not null) <> (sa_to.id is not null))
    ),
    transfer_converted as (
        select s.*,
            case
                when s.amount_original = 0 then 0::numeric
                when upper(s.source_currency) = upper(s.base_currency) then s.amount_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    s.amount_original, upper(s.source_currency), upper(s.base_currency), s.transfer_date::date
                )
            end as amount_base
        from transfer_source s
    ),
    summary as (
        select
            coalesce(sum(case when transaction_type = 'income' then amount_base else 0 end), 0)::numeric as income_base,
            coalesce(sum(case when transaction_type in ('expense','adjustment') then amount_base else 0 end), 0)::numeric as expense_base,
            coalesce(sum(case when transaction_type = 'income' then amount_original else 0 end), 0)::numeric as income_original,
            coalesce(sum(case when transaction_type in ('expense','adjustment') then amount_original else 0 end), 0)::numeric as expense_original,
            count(*) filter (where amount_base is null)::bigint as tx_missing
        from tx_converted
    ),
    transfer_summary as (
        select
            coalesce(sum(case when transfer_direction = 'incoming' then amount_base else 0 end), 0)::numeric as income_base,
            coalesce(sum(case when transfer_direction = 'outgoing' then amount_base else 0 end), 0)::numeric as expense_base,
            coalesce(sum(case when transfer_direction = 'incoming' then amount_original else 0 end), 0)::numeric as income_original,
            coalesce(sum(case when transfer_direction = 'outgoing' then amount_original else 0 end), 0)::numeric as expense_original,
            coalesce(sum(case when transfer_direction = 'incoming' then amount_base else -amount_base end), 0)::numeric as transfer_base,
            count(*) filter (where amount_base is null)::bigint as transfer_missing
        from transfer_converted
    ),
    tx_items as (
        select jsonb_build_object(
            'id', t.id,
            'transaction_type', t.transaction_type,
            'account_id', t.account_id,
            'account_name', t.account_name,
            'amount_original', t.amount_original,
            'amount_base', t.amount_base,
            'currency_original', t.source_currency,
            'category_id', t.category_id,
            'description', t.description,
            'transaction_date', t.transaction_date,
            'source_kind', t.source_kind
        ) as item, t.transaction_date as event_date, 'tx-' || t.id::text as stable_id
        from tx_converted t
    ),
    transfer_items as (
        select jsonb_build_object(
            'id', 'transfer-' || t.id::text,
            'transfer_id', t.id,
            'transaction_type', 'transfer',
            'transfer_type', t.transfer_type,
            'transfer_direction', t.transfer_direction,
            'account_id', t.scoped_account_id,
            'account_name', t.account_name,
            'amount_original', t.amount_original,
            'amount_base', t.amount_base,
            'currency_original', t.source_currency,
            'description', case when t.transfer_direction = 'incoming' then 'Входящий перевод' else 'Исходящий перевод' end,
            'transaction_date', t.transfer_date
        ) as item, t.transfer_date as event_date, 'tr-' || t.id::text as stable_id
        from transfer_converted t
    ),
    all_items as (
        select * from tx_items
        union all
        select * from transfer_items
    ),
    items as (
        select coalesce(jsonb_agg(item order by event_date desc, stable_id desc), '[]'::jsonb) as transactions
        from all_items
    ),
    scope_meta as (
        select count(*)::bigint as scope_count, min(currency_code)::text as only_currency from scope_accounts
    )
    select
        v_user_id,
        uc.base_currency,
        p_account_id,
        p_date_from,
        p_date_to,
        p_include_descendants,
        sm.scope_count,
        case when sm.scope_count = 1 then s.income_original + ts.income_original else s.income_base + ts.income_base end,
        case when sm.scope_count = 1 then s.expense_original + ts.expense_original else s.expense_base + ts.expense_base end,
        case when sm.scope_count = 1
             then s.income_original + ts.income_original - s.expense_original - ts.expense_original
             else s.income_base + ts.income_base - s.expense_base - ts.expense_base
        end,
        ts.transfer_base,
        ((select count(*) from tx_converted) + (select count(*) from transfer_converted))::bigint,
        (s.tx_missing + ts.transfer_missing)::bigint,
        case when sm.scope_count = 1 then sm.only_currency else uc.base_currency end,
        i.transactions
    from user_ctx uc
    cross join summary s
    cross join transfer_summary ts
    cross join items i
    cross join scope_meta sm;
end;
$function$;

comment on function moneytrack.api_transactions_read_model_v2(bigint,bigint,date,date,boolean,bigint[],bigint[],bigint[])
is 'UX-024 account operations read model: preserves UX-022R3 turnover semantics and exposes persisted source_kind for transaction rows.';

commit;
