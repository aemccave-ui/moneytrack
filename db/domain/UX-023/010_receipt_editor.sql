-- MoneyTrack — UX-023 — receipt detail/editor backend boundaries
-- UI edits are intentionally limited to receipt accounting (account + currency)
-- and receipt-item category. Shop, total, item description/amount and receipt
-- clock remain immutable parser output.

begin;

create or replace function moneytrack.api_receipt_detail_read_model_v1(
    p_telegram_user_id bigint,
    p_transaction_id bigint
)
returns table (
    user_found boolean,
    receipt_found boolean,
    receipt jsonb
)
language sql
stable
as $function$
    with user_ctx as (
        select
            u.id as internal_user_id,
            coalesce(s.language_code, u.language_code, 'en')::text as language_code
        from moneytrack.app_users u
        left join moneytrack.user_settings s on s.user_id = u.id
        where u.telegram_user_id = p_telegram_user_id
        limit 1
    ),
    receipt_row as (
        select
            r.id,
            r.transaction_id,
            r.receipt_date,
            r.shop_name,
            r.total_amount,
            r.currency,
            r.status,
            t.transaction_date,
            t.account_id,
            a.name as account_name,
            upper(a.currency_code)::text as account_currency
        from moneytrack.receipts r
        join user_ctx uc on uc.internal_user_id = r.user_id
        join moneytrack.transactions t
          on t.id = r.transaction_id
         and t.user_id = r.user_id
        join moneytrack.accounts a
          on a.id = t.account_id
         and a.user_id = t.user_id
        where r.transaction_id = p_transaction_id
        order by r.id desc
        limit 1
    ),
    item_rows as (
        select coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'id', ri.id,
                    'description', ri.item_name_original,
                    'item_name_original', ri.item_name_original,
                    'quantity', ri.quantity,
                    'unit_price', ri.unit_price,
                    'amount', coalesce(ri.amount, ri.unit_price * coalesce(ri.quantity, 1)),
                    'category_id', ri.category_id,
                    'category_code', cc.code,
                    'category_name', coalesce(t_user.name, t_en.name, cc.code)
                )
                order by ri.id
            ),
            '[]'::jsonb
        ) as items
        from receipt_row rr
        join moneytrack.receipt_items ri on ri.receipt_id = rr.id
        cross join user_ctx uc
        left join moneytrack.category_catalog cc on cc.id = ri.category_id
        left join moneytrack.category_catalog_translations t_user
          on t_user.category_id = cc.id
         and t_user.language_code = uc.language_code
        left join moneytrack.category_catalog_translations t_en
          on t_en.category_id = cc.id
         and t_en.language_code = 'en'
    )
    select
        exists(select 1 from user_ctx),
        exists(select 1 from receipt_row),
        case when exists(select 1 from receipt_row) then (
            select jsonb_build_object(
                'id', rr.id,
                'transaction_id', rr.transaction_id,
                'shop_name', rr.shop_name,
                'total_amount', rr.total_amount,
                'currency', rr.currency,
                'receipt_date', rr.receipt_date,
                'transaction_date', rr.transaction_date,
                'account_id', rr.account_id,
                'account_name', rr.account_name,
                'account_currency', rr.account_currency,
                'status', rr.status,
                'items', ir.items
            )
            from receipt_row rr
            cross join item_rows ir
        ) else null::jsonb end;
$function$;

comment on function moneytrack.api_receipt_detail_read_model_v1(bigint,bigint)
is 'UX-023 owned receipt read model for MiniApp modal. Returns immutable parser fields, accounting account/currency, and receipt-item category IDs/names; no raw AI payload is exposed.';

create or replace function moneytrack.receipt_update_accounting_v1(
    p_user_id bigint,
    p_receipt_id bigint,
    p_account_id bigint,
    p_currency text
)
returns table (
    status text,
    receipt_id bigint,
    transaction_id bigint,
    account_id bigint,
    account_name text,
    account_currency text,
    currency text,
    amount_base numeric,
    currency_base text,
    exchange_rate numeric
)
language plpgsql
volatile
as $function$
declare
    v_currency text := upper(nullif(btrim(p_currency), ''));
    v_transaction_id bigint;
    v_amount_original numeric;
    v_transaction_date timestamptz;
    v_base_currency text;
    v_account_name text;
    v_account_currency text;
    v_amount_base numeric;
    v_rate numeric;
begin
    if p_user_id is null or p_receipt_id is null then
        raise exception 'USER_AND_RECEIPT_REQUIRED' using errcode = '22023';
    end if;
    if p_account_id is null then
        raise exception 'ACCOUNT_REQUIRED' using errcode = '22023';
    end if;
    if v_currency is null then
        raise exception 'CURRENCY_REQUIRED' using errcode = '22023';
    end if;
    if not exists (
        select 1 from moneytrack.currencies c
        where upper(c.code) = v_currency
          and coalesce(c.is_active, true) = true
    ) then
        raise exception 'CURRENCY_NOT_FOUND: %', v_currency using errcode = 'P0002';
    end if;

    select
        r.transaction_id,
        t.amount_original,
        t.transaction_date,
        upper(coalesce(s.base_currency, u.default_currency, 'EUR'))
      into
        v_transaction_id,
        v_amount_original,
        v_transaction_date,
        v_base_currency
      from moneytrack.receipts r
      join moneytrack.transactions t
        on t.id = r.transaction_id
       and t.user_id = r.user_id
      join moneytrack.app_users u on u.id = r.user_id
      left join moneytrack.user_settings s on s.user_id = u.id
     where r.id = p_receipt_id
       and r.user_id = p_user_id
     for update of r, t;

    if not found then
        raise exception 'RECEIPT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    select a.name, upper(a.currency_code)
      into v_account_name, v_account_currency
      from moneytrack.accounts a
     where a.id = p_account_id
       and a.user_id = p_user_id
       and coalesce(a.is_active, true) = true;

    if not found then
        raise exception 'ACCOUNT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    if exists (
        select 1
          from moneytrack.accounts child
         where child.parent_id = p_account_id
           and child.user_id = p_user_id
           and coalesce(child.is_active, true) = true
    ) then
        raise exception 'ACCOUNT_GROUP_NOT_POSTABLE' using errcode = '22023';
    end if;

    if v_account_currency <> v_currency then
        raise exception 'ACCOUNT_CURRENCY_MISMATCH: account %, receipt %',
            v_account_currency, v_currency using errcode = '22023';
    end if;

    if v_currency = v_base_currency then
        v_amount_base := v_amount_original;
        v_rate := 1;
    else
        v_amount_base := moneytrack.finance_fx_convert_usd_bridge_v1(
            v_amount_original,
            v_currency,
            v_base_currency,
            v_transaction_date::date
        );
        if v_amount_base is null then
            raise exception 'FX_RATE_NOT_FOUND: % -> % at %',
                v_currency, v_base_currency, v_transaction_date::date using errcode = 'P0001';
        end if;
        v_rate := v_amount_base / nullif(v_amount_original, 0);
    end if;

    update moneytrack.receipts r
       set currency = v_currency
     where r.id = p_receipt_id
       and r.user_id = p_user_id;

    update moneytrack.transactions t
       set account_id = p_account_id,
           currency_original = v_currency,
           amount_base = v_amount_base,
           currency_base = v_base_currency,
           exchange_rate = v_rate
     where t.id = v_transaction_id
       and t.user_id = p_user_id;

    return query
    select
        'updated'::text,
        p_receipt_id,
        v_transaction_id,
        p_account_id,
        v_account_name,
        v_account_currency,
        v_currency,
        v_amount_base,
        v_base_currency,
        v_rate;
end;
$function$;

comment on function moneytrack.receipt_update_accounting_v1(bigint,bigint,bigint,text)
is 'UX-023 atomic receipt accounting correction. Caller explicitly chooses account and currency; backend rejects inactive/group/foreign accounts and any account/receipt currency mismatch, then recomputes base valuation.';

create or replace function moneytrack.receipt_set_item_category_v2(
    p_user_id bigint,
    p_receipt_item_id bigint,
    p_category_id bigint
)
returns table (
    status text,
    receipt_item_id bigint,
    receipt_id bigint,
    category_id bigint,
    category_code text,
    category_name text,
    transaction_category_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_receipt_id bigint;
    v_transaction_id bigint;
    v_product_id bigint;
    v_category_code text;
    v_category_name text;
    v_language_code text;
    v_distinct_categories integer;
    v_transaction_category_id bigint;
begin
    if p_user_id is null or p_receipt_item_id is null then
        raise exception 'USER_AND_RECEIPT_ITEM_REQUIRED' using errcode = '22023';
    end if;

    select coalesce(s.language_code, u.language_code, 'en')
      into v_language_code
      from moneytrack.app_users u
      left join moneytrack.user_settings s on s.user_id = u.id
     where u.id = p_user_id;

    if v_language_code is null then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    select ri.receipt_id, r.transaction_id, ri.product_id
      into v_receipt_id, v_transaction_id, v_product_id
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id = ri.receipt_id
     where ri.id = p_receipt_item_id
       and r.user_id = p_user_id
     for update of ri;

    if not found then
        raise exception 'RECEIPT_ITEM_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    if p_category_id is not null then
        select c.code, coalesce(t_user.name, t_en.name, c.code)
          into v_category_code, v_category_name
          from moneytrack.category_catalog c
          left join moneytrack.category_catalog_translations t_user
            on t_user.category_id = c.id
           and t_user.language_code = v_language_code
          left join moneytrack.category_catalog_translations t_en
            on t_en.category_id = c.id
           and t_en.language_code = 'en'
         where c.id = p_category_id
           and c.user_id = p_user_id
           and coalesce(c.is_active, true) = true;

        if not found then
            raise exception 'CATEGORY_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
        end if;
    end if;

    update moneytrack.receipt_items ri
       set category_id = p_category_id
     where ri.id = p_receipt_item_id;

    if v_product_id is not null then
        update moneytrack.product_catalog pc
           set category_id = p_category_id
         where pc.id = v_product_id
           and pc.user_id = p_user_id;
    end if;

    select count(distinct ri.category_id)::integer, min(ri.category_id)
      into v_distinct_categories, v_transaction_category_id
      from moneytrack.receipt_items ri
     where ri.receipt_id = v_receipt_id
       and ri.category_id is not null;

    if v_distinct_categories <> 1 then
        v_transaction_category_id := null;
    end if;

    update moneytrack.transactions t
       set category_id = v_transaction_category_id
     where t.id = v_transaction_id
       and t.user_id = p_user_id;

    return query
    select
        'updated'::text,
        p_receipt_item_id,
        v_receipt_id,
        p_category_id,
        v_category_code,
        v_category_name,
        v_transaction_category_id;
end;
$function$;

comment on function moneytrack.receipt_set_item_category_v2(bigint,bigint,bigint)
is 'UX-023 ID-based manual receipt-item category update for MiniApp. Updates item/product and keeps the receipt transaction category conservative: one distinct classified category or NULL.';

commit;
