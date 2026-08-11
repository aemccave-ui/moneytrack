-- MoneyTrack — UX-022R3 — all-operation turnover semantics
-- Period cards must reconcile with the operations visible to the user:
-- incoming transfer = income movement; outgoing transfer = expense movement.
-- The legacy `transfers` field on api_transactions_read_model_v2 remains net transfer flow.

begin;

create or replace function moneytrack.api_accounts_explorer_summary_read_model_v2(
    p_telegram_user_id bigint,
    p_selected_account_ids bigint[],
    p_income_category_ids bigint[],
    p_expense_category_ids bigint[],
    p_date_from date,
    p_date_to date,
    p_as_of date
)
returns table (
    user_id bigint,
    base_currency text,
    total_base numeric,
    account_balances jsonb,
    snapshot_missing_rate_count bigint,
    period_income numeric,
    period_expense numeric,
    period_result numeric,
    period_count bigint,
    date_from date,
    date_to date
)
language plpgsql
stable
as $function$
declare
    v_user_id bigint := moneytrack.ux022_resolve_user_id_v1(p_telegram_user_id);
begin
    if p_date_from is null or p_date_to is null or p_as_of is null then
        raise exception 'DATE_REQUIRED' using errcode = '22023';
    end if;
    if p_date_from > p_date_to then raise exception 'DATE_RANGE_INVALID' using errcode = '22023'; end if;

    return query
    with
    user_ctx as (
        select u.id as internal_user_id,
               coalesce(s.base_currency, u.default_currency, 'EUR')::text as base_currency
        from moneytrack.app_users u
        left join moneytrack.user_settings s on s.user_id = u.id
        where u.id = v_user_id
    ),
    active_accounts as (
        select a.id, a.currency_code
        from moneytrack.accounts a
        where a.user_id = v_user_id and coalesce(a.is_active, true) = true
    ),
    selected_accounts as (
        select a.id, a.currency_code
        from active_accounts a
        where p_selected_account_ids is null or a.id = any(p_selected_account_ids)
    ),
    transaction_movements as (
        select t.account_id,
            case
                when t.transaction_type in ('openingbalance','income') then t.amount_original
                when t.transaction_type = 'expense' then -t.amount_original
                when t.transaction_type = 'adjustment' then t.amount_original
                else 0
            end as amount
        from moneytrack.transactions t
        where t.user_id = v_user_id
          and t.transaction_date < (p_as_of + 1)::date
    ),
    transfer_movements as (
        select t.from_account_id as account_id, -t.from_amount as amount
        from moneytrack.transfers t
        where t.user_id = v_user_id and t.transfer_date < (p_as_of + 1)::date
        union all
        select t.to_account_id as account_id, t.to_amount as amount
        from moneytrack.transfers t
        where t.user_id = v_user_id and t.transfer_date < (p_as_of + 1)::date
    ),
    movements as (
        select * from transaction_movements
        union all
        select * from transfer_movements
    ),
    own_balances as (
        select a.id as account_id, a.currency_code,
               coalesce(sum(m.amount), 0)::numeric as balance_original
        from active_accounts a
        left join movements m on m.account_id = a.id
        group by a.id, a.currency_code
    ),
    converted_balances as (
        select ob.account_id, ob.currency_code, ob.balance_original,
            case
                when ob.balance_original = 0 then 0::numeric
                when upper(ob.currency_code) = upper(uc.base_currency) then ob.balance_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    ob.balance_original, upper(ob.currency_code), upper(uc.base_currency), p_as_of
                )
            end as balance_base
        from own_balances ob
        cross join user_ctx uc
    ),
    period_transactions as (
        select t.id, t.account_id, t.transaction_type,
               abs(coalesce(t.amount_original, 0)) as amount_original,
               coalesce(nullif(t.currency_original, ''), a.currency_code, uc.base_currency)::text as source_currency,
               t.category_id, t.transaction_date, uc.base_currency
        from moneytrack.transactions t
        join selected_accounts sa on sa.id = t.account_id
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
    converted_period as (
        select pt.*,
            case
                when pt.amount_original = 0 then 0::numeric
                when upper(pt.source_currency) = upper(pt.base_currency) then pt.amount_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    pt.amount_original, upper(pt.source_currency), upper(pt.base_currency), pt.transaction_date::date
                )
            end as amount_base
        from period_transactions pt
    ),
    period_transfer_sides as (
        select tr.id,
               'outgoing'::text as transfer_direction,
               abs(coalesce(tr.from_amount, 0))::numeric as amount_original,
               coalesce(nullif(tr.from_currency, ''), a.currency_code, uc.base_currency)::text as source_currency,
               tr.transfer_date,
               uc.base_currency
        from moneytrack.transfers tr
        join selected_accounts sa on sa.id = tr.from_account_id
        left join moneytrack.accounts a on a.id = tr.from_account_id and a.user_id = tr.user_id
        cross join user_ctx uc
        where tr.user_id = v_user_id
          and tr.transfer_date >= p_date_from
          and tr.transfer_date < (p_date_to + 1)::date

        union all

        select tr.id,
               'incoming'::text as transfer_direction,
               abs(coalesce(tr.to_amount, 0))::numeric as amount_original,
               coalesce(nullif(tr.to_currency, ''), a.currency_code, uc.base_currency)::text as source_currency,
               tr.transfer_date,
               uc.base_currency
        from moneytrack.transfers tr
        join selected_accounts sa on sa.id = tr.to_account_id
        left join moneytrack.accounts a on a.id = tr.to_account_id and a.user_id = tr.user_id
        cross join user_ctx uc
        where tr.user_id = v_user_id
          and tr.transfer_date >= p_date_from
          and tr.transfer_date < (p_date_to + 1)::date
    ),
    converted_period_transfers as (
        select pts.*,
            case
                when pts.amount_original = 0 then 0::numeric
                when upper(pts.source_currency) = upper(pts.base_currency) then pts.amount_original
                else moneytrack.finance_fx_convert_usd_bridge_v1(
                    pts.amount_original, upper(pts.source_currency), upper(pts.base_currency), pts.transfer_date::date
                )
            end as amount_base
        from period_transfer_sides pts
    ),
    period_summary as (
        select
            coalesce(sum(case when transaction_type = 'income' then amount_base else 0 end), 0)::numeric as income,
            coalesce(sum(case when transaction_type in ('expense','adjustment') then amount_base else 0 end), 0)::numeric as expense,
            count(*)::bigint as tx_count
        from converted_period
    ),
    transfer_period_summary as (
        select
            coalesce(sum(case when transfer_direction = 'incoming' then amount_base else 0 end), 0)::numeric as income,
            coalesce(sum(case when transfer_direction = 'outgoing' then amount_base else 0 end), 0)::numeric as expense,
            count(distinct id)::bigint as transfer_count
        from converted_period_transfers
    )
    select
        v_user_id,
        uc.base_currency,
        coalesce((
            select sum(cb.balance_base)
            from converted_balances cb
            join selected_accounts sa on sa.id = cb.account_id
        ), 0)::numeric as total_base,
        coalesce((
            select jsonb_agg(
                jsonb_build_object(
                    'account_id', cb.account_id,
                    'currency_code', cb.currency_code,
                    'balance_original', cb.balance_original,
                    'balance_base', cb.balance_base
                ) order by cb.account_id
            )
            from converted_balances cb
        ), '[]'::jsonb) as account_balances,
        (
            select count(*)
            from converted_balances cb
            join selected_accounts sa on sa.id = cb.account_id
            where cb.balance_base is null
        )::bigint as snapshot_missing_rate_count,
        (ps.income + tps.income)::numeric,
        (ps.expense + tps.expense)::numeric,
        (ps.income + tps.income - ps.expense - tps.expense)::numeric,
        (ps.tx_count + tps.transfer_count)::bigint,
        p_date_from,
        p_date_to
    from user_ctx uc
    cross join period_summary ps
    cross join transfer_period_summary tps;
end;
$function$;

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
        select t.id, t.transaction_type, t.account_id, a.name as account_name,
               abs(coalesce(t.amount_original, 0)) as amount_original,
               coalesce(nullif(t.currency_original, ''), a.currency_code, uc.base_currency)::text as source_currency,
               t.category_id, t.description, t.transaction_date, uc.base_currency
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
        select tr.id,
               case when sa_from.id is not null then tr.from_account_id else tr.to_account_id end as scoped_account_id,
               case when sa_from.id is not null then a_from.name else a_to.name end as account_name,
               case when sa_from.id is not null then tr.from_amount else tr.to_amount end as amount_original,
               case when sa_from.id is not null then tr.from_currency else tr.to_currency end as source_currency,
               case when sa_from.id is not null then 'outgoing'::text else 'incoming'::text end as transfer_direction,
               coalesce(tr.transfer_type, 'transfer')::text as transfer_type,
               tr.transfer_date, uc.base_currency
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
            'transaction_date', t.transaction_date
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

comment on function moneytrack.api_accounts_explorer_summary_read_model_v2(bigint,bigint[],bigint[],bigint[],date,date,date)
is 'UX-022R3 Accounts Explorer summary: balances are snapshots; period turnover includes all selected-account transaction and transfer movements.';
comment on function moneytrack.api_transactions_read_model_v2(bigint,bigint,date,date,boolean,bigint[],bigint[],bigint[])
is 'UX-022R3 account operations read model: period income/expense/result reconcile with visible transaction + external-transfer rows; transfers remains net flow.';

commit;
