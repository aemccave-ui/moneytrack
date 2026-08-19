-- MoneyTrack — SPC-001C — Home operation-open contract repair
--
-- Restores the UX-024 source metadata contract on the Space-native dashboard
-- and restores the UX-023 read semantics where an ordinary transaction may
-- legitimately have no receipt. SOURCE ONLY until controlled runtime apply.

begin;

-- ---------------------------------------------------------------------------
-- Home latest_operations must expose canonical persisted source metadata.
-- The capture event is authoritative after SPC-001C; transaction.source_type is
-- retained as a compatibility fallback for records not yet attached to an event.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.finance_dashboard_space_read_model_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_as_of date
)
returns table (
    actor_user_id bigint,
    space_id bigint,
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
language plpgsql
stable
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    return query
    with ctx as (
        select s.base_currency,s.report_currency,
               coalesce(us.language_code,u.language_code,'en')::text as language_code,
               date_trunc('month',p_as_of)::date as date_from,
               (date_trunc('month',p_as_of)+interval '1 month - 1 day')::date as date_to
        from moneytrack.space_financial_settings s
        join moneytrack.app_users u on u.id=p_actor_user_id
        left join moneytrack.user_settings us on us.user_id=p_actor_user_id
        where s.space_id=p_space_id
    ),
    tx_movements as (
        select t.account_id,
               case when t.transaction_type in ('openingbalance','income') then t.amount_original
                    when t.transaction_type='expense' then -t.amount_original
                    when t.transaction_type='adjustment' then t.amount_original else 0 end as amount
        from moneytrack.transactions t where t.space_id=p_space_id
    ),
    transfer_movements as (
        select tr.from_account_id as account_id,-tr.from_amount as amount from moneytrack.transfers tr where tr.space_id=p_space_id
        union all
        select tr.to_account_id as account_id,tr.to_amount as amount from moneytrack.transfers tr where tr.space_id=p_space_id
    ),
    movements as (
        select * from tx_movements union all select * from transfer_movements
    ),
    raw_balances as (
        select a.id,a.currency_code,coalesce(sum(m.amount),0) as balance_original
        from moneytrack.accounts a
        left join movements m on m.account_id=a.id
        where a.space_id=p_space_id and coalesce(a.is_active,true)=true
        group by a.id,a.currency_code
    ),
    converted_balances as (
        select rb.*,
               case when rb.currency_code=ctx.base_currency then rb.balance_original
                    else moneytrack.finance_fx_convert_usd_bridge_v1(rb.balance_original,rb.currency_code,ctx.base_currency,p_as_of) end as balance_base
        from raw_balances rb cross join ctx
    ),
    month_tx as (
        select t.transaction_type,abs(coalesce(t.amount_original,0)) as amount_original,
               coalesce(nullif(t.currency_original,''),a.currency_code,ctx.base_currency)::text as source_currency,
               t.transaction_date,ctx.base_currency
        from moneytrack.transactions t
        join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
        cross join ctx
        where t.space_id=p_space_id
          and t.transaction_date>=ctx.date_from and t.transaction_date<(ctx.date_to+1)::date
    ),
    converted_month as (
        select mt.transaction_type,
               case when mt.source_currency=mt.base_currency then mt.amount_original
                    else moneytrack.finance_fx_convert_usd_bridge_v1(mt.amount_original,mt.source_currency,mt.base_currency,mt.transaction_date::date) end as amount_base
        from month_tx mt
    ),
    month_summary as (
        select coalesce(sum(case when transaction_type='income' then amount_base else 0 end),0) as income,
               coalesce(sum(case when transaction_type='expense' then amount_base else 0 end),0) as expense
        from converted_month
    ),
    by_currency as (
        select coalesce(jsonb_agg(jsonb_build_object('currency_code',x.currency_code,'balance_original',x.balance_original) order by x.currency_code),'[]'::jsonb) as payload
        from (select rb.currency_code,sum(rb.balance_original) as balance_original from raw_balances rb group by rb.currency_code) x
    ),
    latest as (
        select coalesce(jsonb_agg(to_jsonb(x) order by x.transaction_date desc,x.id desc),'[]'::jsonb) as payload
        from (
            select
                t.id,t.transaction_type,t.account_id,a.name as account_name,t.amount_original,t.amount_base,
                t.currency_original,t.category_id,t.description,t.transaction_date,t.created_by_user_id,
                t.source_type,t.capture_event_id,
                coalesce(
                    case
                        when ce.source_type in ('manual','text','voice','photo_receipt') then ce.source_type
                        else null
                    end,
                    case lower(coalesce(t.source_type,''))
                        when 'miniapp' then 'manual'
                        when 'manual' then 'manual'
                        when 'text' then 'text'
                        when 'voice' then 'voice'
                        when 'photo' then 'photo_receipt'
                        when 'photo_receipt' then 'photo_receipt'
                        else null
                    end
                )::text as source_kind
            from moneytrack.transactions t
            join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
            left join moneytrack.capture_events ce on ce.id=t.capture_event_id
            where t.space_id=p_space_id
            order by t.transaction_date desc,t.id desc
            limit 10
        ) x
    )
    select p_actor_user_id,p_space_id,ctx.base_currency,ctx.report_currency,ctx.language_code,
           ctx.date_from,ctx.date_to,
           coalesce((select sum(cb.balance_base) from converted_balances cb),0),
           ms.income,ms.expense,ms.income-ms.expense,bc.payload,l.payload
    from ctx cross join month_summary ms cross join by_currency bc cross join latest l;
end;
$function$;

comment on function moneytrack.finance_dashboard_space_read_model_v1(bigint,bigint,date)
is 'SPC-001 Space dashboard. Home latest_operations exposes source_type/source_kind so ordinary operations open the transaction editor and photo receipts open the receipt modal.';

-- ---------------------------------------------------------------------------
-- Receipt lookup compatibility.
-- A transaction that exists in the active Space but has no receipt is a normal
-- result and returns NULL. A transaction outside the Space remains fail-closed.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.receipt_projection_api_read_v1(
    p_actor_user_id bigint,p_space_id bigint,p_transaction_id bigint
)
returns jsonb
language plpgsql stable as $function$
declare v_result jsonb;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if not exists (
        select 1
        from moneytrack.transactions t
        where t.id=p_transaction_id
          and t.space_id=p_space_id
    ) then
        raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    select jsonb_build_object(
      'id',cr.id,'transaction_id',t.id,'space_id',t.space_id,
      'shop_name',cr.merchant,'receipt_date',cr.recognized_at,'transaction_date',t.transaction_date,
      'total_amount',cr.total_amount,'currency',t.currency_original,
      'recognized_currency',cr.currency,'account_id',t.account_id,'account_name',a.name,
      'items',coalesce((select jsonb_agg(jsonb_build_object(
        'id',cri.id,'description',cri.item_name_original,'item_name_original',cri.item_name_original,
        'item_language',cri.item_language,'quantity',cri.quantity,'unit_price',cri.unit_price,'amount',cri.amount,
        'category_id',pc.category_id,'category_name',coalesce(tr.name,cat.code),'category_code',cat.code,'product_id',pc.product_id
      ) order by cri.id)
      from moneytrack.capture_receipt_items cri
      left join moneytrack.receipt_item_projection_classification pc on pc.transaction_id=t.id and pc.capture_receipt_item_id=cri.id
      left join moneytrack.category_catalog cat on cat.id=pc.category_id and cat.space_id=t.space_id
      left join moneytrack.user_settings us on us.user_id=p_actor_user_id
      left join moneytrack.app_users au on au.id=p_actor_user_id
      left join moneytrack.category_catalog_translations tr on tr.category_id=cat.id and tr.language_code=coalesce(us.language_code,au.language_code,'en')
      where cri.capture_receipt_id=cr.id),'[]'::jsonb)
    ) into v_result
    from moneytrack.transactions t
    join moneytrack.accounts a on a.id=t.account_id and a.space_id=t.space_id
    join moneytrack.capture_receipts cr on cr.capture_event_id=t.capture_event_id
    where t.id=p_transaction_id and t.space_id=p_space_id;

    -- NULL here means "ordinary operation, no receipt" and is intentionally
    -- serialized by the dispatcher as { receipt: null }.
    return v_result;
end;$function$;

comment on function moneytrack.receipt_projection_api_read_v1(bigint,bigint,bigint)
is 'SPC-001 receipt read compatibility: returns NULL for an existing Space transaction without a receipt; unknown/out-of-Space transaction ids fail closed.';

commit;
