-- MoneyTrack — BE-DOM-002 — receipt/catalog domain boundaries
--
-- Goal: active n8n workflows remain orchestration/adapters while ownership,
-- duplicate protection, catalog resolution and receipt persistence live in
-- PostgreSQL backend boundaries.

begin;

create or replace function moneytrack.catalog_ensure_user_categories_v1(
    p_user_id bigint
)
returns table (
    status text,
    inserted_category_count integer,
    inserted_translation_count integer
)
language plpgsql
volatile
as $function$
declare
    v_parent_count integer := 0;
    v_child_count integer := 0;
    v_translation_count integer := 0;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if not exists (
        select 1 from moneytrack.app_users u where u.id = p_user_id
    ) then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    -- Serialize bootstrap for one user. The canonical source is template user 0.
    perform pg_advisory_xact_lock(
        hashtextextended('BE-DOM-002:catalog-bootstrap:' || p_user_id::text, 0)
    );

    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order
    )
    select
        p_user_id,
        tc.code,
        null,
        tc.is_active,
        tc.sort_order,
        now(),
        tc.show_in_budget_report,
        tc.budget_sort_order
    from moneytrack.category_catalog tc
    where tc.user_id = 0
      and tc.parent_id is null
      and not exists (
          select 1
          from moneytrack.category_catalog existing
          where existing.user_id = p_user_id
            and existing.code = tc.code
      )
    on conflict (user_id, code) do nothing;

    get diagnostics v_parent_count = row_count;

    -- Preserve the current template topology: parent + child levels.
    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order
    )
    select
        p_user_id,
        tc.code,
        target_parent.id,
        tc.is_active,
        tc.sort_order,
        now(),
        tc.show_in_budget_report,
        tc.budget_sort_order
    from moneytrack.category_catalog tc
    join moneytrack.category_catalog template_parent
      on template_parent.id = tc.parent_id
     and template_parent.user_id = 0
    join moneytrack.category_catalog target_parent
      on target_parent.user_id = p_user_id
     and target_parent.code = template_parent.code
    where tc.user_id = 0
      and tc.parent_id is not null
      and not exists (
          select 1
          from moneytrack.category_catalog existing
          where existing.user_id = p_user_id
            and existing.code = tc.code
      )
    on conflict (user_id, code) do nothing;

    get diagnostics v_child_count = row_count;

    insert into moneytrack.category_catalog_translations (
        category_id, language_code, name
    )
    select
        target.id,
        tr.language_code,
        tr.name
    from moneytrack.category_catalog template
    join moneytrack.category_catalog target
      on target.user_id = p_user_id
     and target.code = template.code
    join moneytrack.category_catalog_translations tr
      on tr.category_id = template.id
    where template.user_id = 0
      and not exists (
          select 1
          from moneytrack.category_catalog_translations existing
          where existing.category_id = target.id
            and existing.language_code = tr.language_code
      );

    get diagnostics v_translation_count = row_count;

    return query
    select
        'ready'::text,
        (v_parent_count + v_child_count)::integer,
        v_translation_count::integer;
end;
$function$;

comment on function moneytrack.catalog_ensure_user_categories_v1(bigint)
is 'BE-DOM-002 category bootstrap boundary. Copies the canonical template-user category tree/translations for one user under backend serialization.';


create or replace function moneytrack.receipt_ingest_v1(
    p_user_id bigint,
    p_account_id bigint,
    p_total_amount numeric,
    p_currency text,
    p_shop_name text,
    p_receipt_date date,
    p_telegram_file_id text,
    p_receipt_fingerprint text,
    p_raw_ai_json jsonb,
    p_items jsonb
)
returns table (
    status text,
    transaction_id bigint,
    receipt_id bigint,
    created_item_count integer,
    duplicate_receipt_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_transaction_id bigint;
    v_receipt_id bigint;
    v_duplicate_id bigint;
    v_item jsonb;
    v_item_name text;
    v_item_language text;
    v_quantity numeric;
    v_unit_price numeric;
    v_amount numeric;
    v_requested_category_id bigint;
    v_effective_category_id bigint;
    v_product_id bigint;
    v_product_category_id bigint;
    v_product_key text;
    v_item_count integer := 0;
begin
    if p_user_id is null then
        raise exception 'USER_REQUIRED' using errcode = '22023';
    end if;

    if p_account_id is null then
        raise exception 'ACCOUNT_REQUIRED' using errcode = '22023';
    end if;

    if p_total_amount is null or p_total_amount <= 0 then
        raise exception 'INVALID_RECEIPT_TOTAL' using errcode = '22023';
    end if;

    if p_currency is null or btrim(p_currency) = '' then
        raise exception 'CURRENCY_REQUIRED' using errcode = '22023';
    end if;

    if p_items is null or jsonb_typeof(p_items) <> 'array' then
        raise exception 'ITEMS_ARRAY_REQUIRED' using errcode = '22023';
    end if;

    if not exists (
        select 1 from moneytrack.app_users u where u.id = p_user_id
    ) then
        raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;

    -- Lock duplicate identities in a stable order before checking absence.
    -- This closes the race that the old n8n read-then-write sequence could not.
    if nullif(btrim(p_telegram_file_id), '') is not null then
        perform pg_advisory_xact_lock(
            hashtextextended(
                'BE-DOM-002:receipt-file:' || p_user_id::text || ':' || p_telegram_file_id,
                0
            )
        );
    end if;

    if nullif(btrim(p_receipt_fingerprint), '') is not null then
        perform pg_advisory_xact_lock(
            hashtextextended(
                'BE-DOM-002:receipt-fingerprint:' || p_user_id::text || ':' || p_receipt_fingerprint,
                0
            )
        );
    end if;

    if nullif(btrim(p_telegram_file_id), '') is not null then
        select r.id
          into v_duplicate_id
          from moneytrack.receipts r
         where r.user_id = p_user_id
           and r.telegram_file_id = p_telegram_file_id
         order by r.id desc
         limit 1;

        if v_duplicate_id is not null then
            return query
            select 'duplicate_exact'::text, null::bigint, null::bigint, 0::integer, v_duplicate_id;
            return;
        end if;
    end if;

    if nullif(btrim(p_receipt_fingerprint), '') is not null then
        select r.id
          into v_duplicate_id
          from moneytrack.receipts r
         where r.user_id = p_user_id
           and r.receipt_fingerprint = p_receipt_fingerprint
         order by r.id desc
         limit 1;

        if v_duplicate_id is not null then
            return query
            select 'duplicate_semantic'::text, null::bigint, null::bigint, 0::integer, v_duplicate_id;
            return;
        end if;
    end if;

    select c.id
      into v_transaction_id
      from moneytrack.finance_create_transaction_v1(
          p_user_id,
          p_account_id,
          'expense',
          p_total_amount,
          upper(p_currency),
          nullif(p_shop_name, ''),
          coalesce(p_receipt_date::timestamptz, current_timestamp),
          null,
          null,
          null
      ) c;

    insert into moneytrack.receipts (
        user_id,
        receipt_fingerprint,
        transaction_id,
        telegram_file_id,
        receipt_date,
        shop_name,
        total_amount,
        currency,
        raw_ai_json,
        status
    ) values (
        p_user_id,
        nullif(p_receipt_fingerprint, ''),
        v_transaction_id,
        nullif(p_telegram_file_id, ''),
        p_receipt_date,
        nullif(p_shop_name, ''),
        p_total_amount,
        upper(p_currency),
        coalesce(p_raw_ai_json, '{}'::jsonb),
        'parsed'
    )
    returning id into v_receipt_id;

    for v_item in
        select value from jsonb_array_elements(p_items)
    loop
        v_item_name := nullif(btrim(v_item->>'item_name_original'), '');

        if v_item_name is null then
            continue;
        end if;

        v_item_language := nullif(btrim(v_item->>'item_language'), '');
        v_quantity := nullif(v_item->>'quantity', '')::numeric;
        v_unit_price := nullif(v_item->>'unit_price', '')::numeric;
        v_amount := nullif(v_item->>'amount', '')::numeric;
        v_requested_category_id := nullif(v_item->>'category_id', '')::bigint;

        if v_item_language is not null and not exists (
            select 1 from moneytrack.languages l where l.code = v_item_language
        ) then
            raise exception 'ITEM_LANGUAGE_NOT_FOUND: %', v_item_language
                using errcode = 'P0002';
        end if;

        if v_requested_category_id is not null and not exists (
            select 1
              from moneytrack.category_catalog c
             where c.id = v_requested_category_id
               and c.user_id = p_user_id
               and coalesce(c.is_active, true) = true
        ) then
            raise exception 'CATEGORY_NOT_FOUND_OR_NOT_OWNED: %', v_requested_category_id
                using errcode = 'P0002';
        end if;

        v_product_key := lower(
            regexp_replace(v_item_name, '[^a-zA-Zа-яА-Я0-9]+', '_', 'g')
        );

        insert into moneytrack.product_catalog (
            user_id,
            product_key,
            original_name,
            original_language,
            category_id,
            is_active,
            created_at
        ) values (
            p_user_id,
            v_product_key,
            v_item_name,
            v_item_language,
            v_requested_category_id,
            true,
            now()
        )
        on conflict (user_id, product_key)
        do update set
            original_name = excluded.original_name,
            original_language = coalesce(
                moneytrack.product_catalog.original_language,
                excluded.original_language
            ),
            is_active = true
        returning id, category_id
          into v_product_id, v_product_category_id;

        v_effective_category_id := coalesce(
            v_requested_category_id,
            v_product_category_id
        );

        insert into moneytrack.receipt_items (
            receipt_id,
            item_name_original,
            item_language,
            quantity,
            unit_price,
            amount,
            category_id,
            product_id
        ) values (
            v_receipt_id,
            v_item_name,
            v_item_language,
            v_quantity,
            v_unit_price,
            v_amount,
            v_effective_category_id,
            v_product_id
        );

        v_item_count := v_item_count + 1;
    end loop;

    return query
    select
        'created'::text,
        v_transaction_id,
        v_receipt_id,
        v_item_count,
        null::bigint;
end;
$function$;

comment on function moneytrack.receipt_ingest_v1(bigint,bigint,numeric,text,text,date,text,text,jsonb,jsonb)
is 'BE-DOM-002 atomic receipt ingest boundary. Serializes duplicate identity, creates the finance transaction, receipt, product upserts and receipt items in one PostgreSQL transaction with ownership validation.';


create or replace function moneytrack.receipt_assign_categories_v1(
    p_user_id bigint,
    p_receipt_id bigint,
    p_assignments jsonb
)
returns table (
    status text,
    updated_product_count integer,
    updated_item_count integer
)
language plpgsql
volatile
as $function$
declare
    v_product_count integer := 0;
    v_item_count integer := 0;
begin
    if p_user_id is null or p_receipt_id is null then
        raise exception 'USER_AND_RECEIPT_REQUIRED' using errcode = '22023';
    end if;

    if not exists (
        select 1
          from moneytrack.receipts r
         where r.id = p_receipt_id
           and r.user_id = p_user_id
    ) then
        raise exception 'RECEIPT_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    if p_assignments is null or jsonb_typeof(p_assignments) <> 'array' then
        raise exception 'ASSIGNMENTS_ARRAY_REQUIRED' using errcode = '22023';
    end if;

    with assignments as (
        select *
        from jsonb_to_recordset(p_assignments)
             as x(product_id bigint, category_id bigint)
    ),
    valid as (
        select distinct a.product_id, a.category_id
        from assignments a
        join moneytrack.product_catalog pc
          on pc.id = a.product_id
         and pc.user_id = p_user_id
        join moneytrack.category_catalog cc
          on cc.id = a.category_id
         and cc.user_id = p_user_id
         and coalesce(cc.is_active, true) = true
        where a.category_id is not null
          and exists (
              select 1
              from moneytrack.receipt_items ri
              where ri.receipt_id = p_receipt_id
                and ri.product_id = pc.id
          )
    ),
    updated as (
        update moneytrack.product_catalog pc
           set category_id = v.category_id
          from valid v
         where pc.id = v.product_id
        returning pc.id
    )
    select count(*)::integer
      into v_product_count
      from updated;

    update moneytrack.receipt_items ri
       set category_id = pc.category_id
      from moneytrack.product_catalog pc
     where ri.receipt_id = p_receipt_id
       and ri.product_id = pc.id
       and pc.user_id = p_user_id
       and ri.category_id is null
       and pc.category_id is not null;

    get diagnostics v_item_count = row_count;

    return query
    select
        case when v_product_count > 0 then 'updated' else 'no_match' end::text,
        v_product_count,
        v_item_count;
end;
$function$;

comment on function moneytrack.receipt_assign_categories_v1(bigint,bigint,jsonb)
is 'BE-DOM-002 receipt category propagation boundary. Applies validated product/category assignments for an owned receipt and propagates product categories into uncategorized receipt items atomically.';


create or replace function moneytrack.receipt_set_item_category_v1(
    p_user_id bigint,
    p_receipt_item_id bigint,
    p_category_hint text
)
returns table (
    receipt_item_id bigint,
    category_hint text,
    item_name_original text,
    product_id bigint,
    category_id bigint,
    category_code text,
    category_name text,
    status text
)
language plpgsql
volatile
as $function$
declare
    v_language_code text;
    v_item_name text;
    v_product_id bigint;
    v_category_id bigint;
    v_category_code text;
    v_category_name text;
    v_normalized_hint text;
begin
    if p_receipt_item_id is null or p_category_hint is null or btrim(p_category_hint) = '' then
        return query
        select p_receipt_item_id, p_category_hint, null::text, null::bigint,
               null::bigint, null::text, null::text, 'invalid_command'::text;
        return;
    end if;

    select us.language_code
      into v_language_code
      from moneytrack.user_settings us
     where us.user_id = p_user_id;

    select ri.item_name_original, ri.product_id
      into v_item_name, v_product_id
      from moneytrack.receipt_items ri
      join moneytrack.receipts r
        on r.id = ri.receipt_id
     where ri.id = p_receipt_item_id
       and r.user_id = p_user_id;

    if not found then
        return query
        select p_receipt_item_id, p_category_hint, null::text, null::bigint,
               null::bigint, null::text, null::text, 'item_not_found'::text;
        return;
    end if;

    v_normalized_hint := lower(
        regexp_replace(p_category_hint, '[^a-zA-Zа-яА-Я0-9]+', '', 'g')
    );

    select c.id, c.code, coalesce(t.name, c.code)
      into v_category_id, v_category_code, v_category_name
      from moneytrack.category_catalog c
      left join moneytrack.category_catalog_translations t
        on t.category_id = c.id
       and t.language_code = v_language_code
     where c.user_id = p_user_id
       and coalesce(c.is_active, true) = true
       and (
            lower(c.code) = lower(p_category_hint)
         or lower(c.code) like '%' || lower(p_category_hint) || '%'
         or lower(coalesce(t.name, '')) = lower(p_category_hint)
         or lower(regexp_replace(coalesce(t.name, ''), '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) = v_normalized_hint
         or lower(regexp_replace(coalesce(t.name, ''), '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) like '%' || v_normalized_hint || '%'
       )
     order by
       case
         when lower(c.code) = lower(p_category_hint) then 0
         when lower(coalesce(t.name, '')) = lower(p_category_hint) then 1
         when lower(regexp_replace(coalesce(t.name, ''), '[^a-zA-Zа-яА-Я0-9]+', '', 'g')) = v_normalized_hint then 2
         when lower(c.code) like '%' || lower(p_category_hint) || '%' then 3
         else 4
       end,
       length(c.code) desc,
       length(coalesce(t.name, c.code))
     limit 1;

    if v_category_id is null then
        return query
        select p_receipt_item_id, p_category_hint, v_item_name, v_product_id,
               null::bigint, null::text, null::text, 'category_not_found'::text;
        return;
    end if;

    update moneytrack.receipt_items ri
       set category_id = v_category_id
     where ri.id = p_receipt_item_id;

    if v_product_id is not null then
        update moneytrack.product_catalog pc
           set category_id = v_category_id
         where pc.id = v_product_id
           and pc.user_id = p_user_id;
    end if;

    return query
    select
        p_receipt_item_id,
        p_category_hint,
        v_item_name,
        v_product_id,
        v_category_id,
        v_category_code,
        v_category_name,
        'updated'::text;
end;
$function$;

comment on function moneytrack.receipt_set_item_category_v1(bigint,bigint,text)
is 'BE-DOM-002 manual receipt-item category boundary. Resolves an owned active category using the legacy code/translation matching contract and updates the receipt item plus its owned product atomically.';

commit;
