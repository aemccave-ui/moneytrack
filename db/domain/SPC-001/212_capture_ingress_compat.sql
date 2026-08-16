-- MoneyTrack — SPC-001C — capture ingress compatibility boundaries
-- SOURCE ONLY until controlled runtime apply.
--
-- MiniApp quick input and trusted Telegram Bot capture share these backend
-- boundaries. Transport chooses destination differently (active Space vs explicit
-- default_capture_space_id), but financial creation and receipt persistence are
-- identical once actor+Space are resolved.

begin;

alter table moneytrack.capture_receipt_items
    add column if not exists source_item_index integer;

create unique index if not exists ux_spc001_capture_receipt_item_index
    on moneytrack.capture_receipt_items(capture_receipt_id,source_item_index)
    where source_item_index is not null;

create or replace function moneytrack.capture_create_projection_compat_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_source_type text,
    p_source_ref text,
    p_account_id bigint,
    p_transaction_type text,
    p_amount_original numeric,
    p_currency_original text,
    p_description text,
    p_transaction_date timestamptz,
    p_category_id bigint default null
)
returns table(
    id bigint,
    user_id bigint,
    space_id bigint,
    account_id bigint,
    transaction_type text,
    amount_original numeric,
    currency_original text,
    amount_base numeric,
    currency_base text,
    exchange_rate numeric,
    description text,
    transaction_date timestamptz,
    source_type text,
    source_id bigint,
    category_id bigint,
    capture_event_id bigint,
    created_by_user_id bigint,
    updated_by_user_id bigint,
    idempotent_replay boolean
)
language plpgsql
volatile
as $function$
declare
    v_event bigint;
    v_transaction bigint;
    v_existing boolean := false;
    v_tx moneytrack.transactions%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if p_source_type not in ('manual','text','voice','photo_receipt') then
        raise exception 'CAPTURE_SOURCE_INVALID' using errcode='22023';
    end if;
    if p_source_ref is null or btrim(p_source_ref)='' then
        raise exception 'CAPTURE_SOURCE_REF_REQUIRED' using errcode='22023';
    end if;

    select e.id into v_event
      from moneytrack.capture_events e
     where e.captured_by_user_id=p_actor_user_id
       and e.source_type=p_source_type
       and e.source_ref=p_source_ref
     limit 1;

    if v_event is not null then
        select t.id into v_transaction
          from moneytrack.transactions t
         where t.capture_event_id=v_event
           and t.space_id=p_space_id
         limit 1;
        v_existing := v_transaction is not null;
    end if;

    select c.capture_event_id,c.transaction_id
      into v_event,v_transaction
      from moneytrack.capture_create_projection_v1(
          p_actor_user_id,
          p_space_id,
          p_source_type,
          p_source_ref,
          p_account_id,
          p_transaction_type,
          p_amount_original,
          p_currency_original,
          p_description,
          p_transaction_date,
          p_category_id,
          jsonb_build_object('source_ref',p_source_ref)
      ) c;

    select * into v_tx
      from moneytrack.transactions t
     where t.id=v_transaction
       and t.space_id=p_space_id;

    if not found then
        raise exception 'CAPTURE_PROJECTION_CREATE_FAILED' using errcode='P0001';
    end if;

    return query
    select
        v_tx.id,
        v_tx.user_id,
        v_tx.space_id,
        v_tx.account_id,
        v_tx.transaction_type,
        v_tx.amount_original,
        v_tx.currency_original,
        v_tx.amount_base,
        v_tx.currency_base,
        v_tx.exchange_rate,
        v_tx.description,
        v_tx.transaction_date,
        v_tx.source_type,
        v_tx.source_id,
        v_tx.category_id,
        v_tx.capture_event_id,
        v_tx.created_by_user_id,
        v_tx.updated_by_user_id,
        v_existing;
end;
$function$;

comment on function moneytrack.capture_create_projection_compat_v1(bigint,bigint,text,text,bigint,text,numeric,text,text,timestamptz,bigint)
is 'SPC-001 capture compatibility boundary. Stable source_ref identifies one real-world capture; replay in one Space returns the existing projection rather than creating a clone.';


create or replace function moneytrack.bot_capture_context_v1(
    p_telegram_user_id bigint
)
returns table(
    actor_user_id bigint,
    space_id bigint,
    space_name text,
    language_code text,
    fallback_language_code text,
    base_currency text,
    report_currency text,
    default_expense_account_id bigint,
    default_income_account_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_actor bigint;
    v_space bigint;
begin
    v_actor:=moneytrack.spc001_resolve_actor_user_id_v1(p_telegram_user_id);
    v_space:=moneytrack.space_resolve_default_capture_v1(v_actor);
    perform moneytrack.assert_space_member_v1(v_actor,v_space);

    return query
    select
        v_actor,
        v_space,
        w.name,
        coalesce(us.language_code,u.language_code,'en'),
        coalesce(u.language_code,'en'),
        s.base_currency,
        s.report_currency,
        s.default_expense_account_id,
        s.default_income_account_id
    from moneytrack.app_users u
    join moneytrack.user_settings us on us.user_id=u.id
    join moneytrack.workspaces w on w.id=v_space and coalesce(w.is_active,true)=true
    join moneytrack.space_financial_settings s on s.space_id=v_space
    where u.id=v_actor;
end;
$function$;

comment on function moneytrack.bot_capture_context_v1(bigint)
is 'SPC-001 trusted Bot capture context. Destination is explicit default_capture_space_id only; current/last active MiniApp Space is never consulted.';


create or replace function moneytrack.capture_receipt_ingest_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_transaction_id bigint,
    p_merchant text,
    p_recognized_at timestamptz,
    p_total_amount numeric,
    p_currency text,
    p_telegram_file_id text,
    p_receipt_fingerprint text,
    p_raw_ai_json jsonb,
    p_items jsonb
)
returns jsonb
language plpgsql
volatile
as $function$
declare
    v_tx moneytrack.transactions%rowtype;
    v_event moneytrack.capture_events%rowtype;
    v_receipt moneytrack.capture_receipts%rowtype;
    v_input jsonb;
    v_ordinal bigint;
    v_item moneytrack.capture_receipt_items%rowtype;
    v_name text;
    v_language text;
    v_quantity numeric;
    v_unit_price numeric;
    v_amount numeric;
    v_category bigint;
    v_product bigint;
    v_product_key text;
    v_existing_count bigint;
    v_result_items jsonb := '[]'::jsonb;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select t.* into v_tx
      from moneytrack.transactions t
     where t.id=p_transaction_id
       and t.space_id=p_space_id
     for update;
    if not found then
        raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;
    if v_tx.capture_event_id is null then
        raise exception 'CAPTURE_EVENT_REQUIRED_FOR_RECEIPT' using errcode='23514';
    end if;

    select e.* into v_event
      from moneytrack.capture_events e
     where e.id=v_tx.capture_event_id;
    if not found or v_event.source_type<>'photo_receipt' then
        raise exception 'PHOTO_RECEIPT_CAPTURE_REQUIRED' using errcode='23514';
    end if;

    if p_items is null or jsonb_typeof(p_items)<>'array' then
        raise exception 'RECEIPT_ITEMS_ARRAY_REQUIRED' using errcode='22023';
    end if;

    select * into v_receipt
      from moneytrack.capture_receipts cr
     where cr.capture_event_id=v_event.id
     for update;

    if not found then
        insert into moneytrack.capture_receipts(
            capture_event_id,merchant,recognized_at,total_amount,currency,
            telegram_file_id,receipt_fingerprint,raw_ai_json,created_at
        ) values (
            v_event.id,
            nullif(btrim(p_merchant),''),
            p_recognized_at,
            p_total_amount,
            upper(nullif(btrim(p_currency),'')),
            nullif(btrim(p_telegram_file_id),''),
            nullif(btrim(p_receipt_fingerprint),''),
            coalesce(p_raw_ai_json,'{}'::jsonb),
            now()
        ) returning * into v_receipt;
    else
        -- Parser facts are immutable after first successful ingest. A retry must
        -- describe the same source; it is not an update API.
        if v_receipt.merchant is distinct from nullif(btrim(p_merchant),'')
           or v_receipt.recognized_at is distinct from p_recognized_at
           or v_receipt.total_amount is distinct from p_total_amount
           or v_receipt.currency is distinct from upper(nullif(btrim(p_currency),''))
           or v_receipt.telegram_file_id is distinct from nullif(btrim(p_telegram_file_id),'')
           or v_receipt.receipt_fingerprint is distinct from nullif(btrim(p_receipt_fingerprint),'')
        then
            raise exception 'RECEIPT_SOURCE_IMMUTABLE_MISMATCH' using errcode='23514';
        end if;
    end if;

    for v_input,v_ordinal in
        select value,ordinality
        from jsonb_array_elements(p_items) with ordinality
    loop
        v_name:=coalesce(nullif(btrim(v_input->>'item_name_original'),''),nullif(btrim(v_input->>'description'),''));
        if v_name is null then
            raise exception 'RECEIPT_ITEM_NAME_REQUIRED' using errcode='22023';
        end if;
        v_language:=nullif(lower(btrim(v_input->>'item_language')),'');
        v_quantity:=coalesce(nullif(v_input->>'quantity','')::numeric,1);
        v_unit_price:=coalesce(nullif(v_input->>'unit_price','')::numeric,nullif(v_input->>'price','')::numeric,nullif(v_input->>'amount','')::numeric,0);
        v_amount:=coalesce(nullif(v_input->>'amount','')::numeric,v_quantity*v_unit_price);
        v_category:=nullif(v_input->>'category_id','')::bigint;

        select * into v_item
          from moneytrack.capture_receipt_items cri
         where cri.capture_receipt_id=v_receipt.id
           and cri.source_item_index=v_ordinal::integer
         for update;

        if not found then
            insert into moneytrack.capture_receipt_items(
                capture_receipt_id,source_item_index,item_name_original,item_language,
                quantity,unit_price,amount,created_at
            ) values (
                v_receipt.id,v_ordinal::integer,v_name,v_language,
                v_quantity,v_unit_price,v_amount,now()
            ) returning * into v_item;
        elsif v_item.item_name_original is distinct from v_name
           or v_item.item_language is distinct from v_language
           or v_item.quantity is distinct from v_quantity
           or v_item.unit_price is distinct from v_unit_price
           or v_item.amount is distinct from v_amount
        then
            raise exception 'RECEIPT_ITEM_SOURCE_IMMUTABLE_MISMATCH: index=%',v_ordinal using errcode='23514';
        end if;

        if v_category is not null and not exists(
            select 1 from moneytrack.category_catalog c
            where c.id=v_category and c.space_id=p_space_id and coalesce(c.is_active,true)=true
        ) then
            raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002';
        end if;

        v_product_key:=lower(regexp_replace(v_name,'[^a-zA-Zа-яА-ЯёЁ0-9]+','_','g'));
        v_product_key:=trim(both '_' from v_product_key);
        if v_product_key='' then
            v_product_key:='item_'||substr(md5(v_name),1,16);
        end if;

        insert into moneytrack.product_catalog(
            user_id,space_id,product_key,original_name,original_language,
            category_id,is_active,created_at,created_by_user_id,updated_by_user_id
        ) values (
            p_actor_user_id,p_space_id,v_product_key,v_name,v_language,
            v_category,true,now(),p_actor_user_id,p_actor_user_id
        )
        on conflict (space_id,product_key) where space_id is not null
        do update set
            original_name=excluded.original_name,
            original_language=coalesce(moneytrack.product_catalog.original_language,excluded.original_language),
            is_active=true,
            updated_by_user_id=p_actor_user_id
        returning id into v_product;

        perform moneytrack.receipt_projection_set_classification_v1(
            p_actor_user_id,p_space_id,p_transaction_id,v_item.id,v_category,v_product
        );

        v_result_items:=v_result_items||jsonb_build_array(jsonb_build_object(
            'id',v_item.id,
            'receipt_item_id',v_item.id,
            'item_name_original',v_item.item_name_original,
            'item_language',v_item.item_language,
            'quantity',v_item.quantity,
            'unit_price',v_item.unit_price,
            'amount',v_item.amount,
            'product_id',v_product,
            'category_id',v_category
        ));
    end loop;

    select count(*) into v_existing_count
      from moneytrack.capture_receipt_items cri
     where cri.capture_receipt_id=v_receipt.id;
    if v_existing_count<>jsonb_array_length(p_items) then
        raise exception 'RECEIPT_ITEM_COUNT_IMMUTABLE_MISMATCH' using errcode='23514';
    end if;

    return jsonb_build_object(
        'id',v_receipt.id,
        'receipt_id',v_receipt.id,
        'transaction_id',v_tx.id,
        'capture_event_id',v_event.id,
        'space_id',p_space_id,
        'shop_name',v_receipt.merchant,
        'receipt_date',v_receipt.recognized_at,
        'total_amount',v_receipt.total_amount,
        'currency',v_receipt.currency,
        'telegram_file_id',v_receipt.telegram_file_id,
        'receipt_fingerprint',v_receipt.receipt_fingerprint,
        'items',v_result_items
    );
end;
$function$;

comment on function moneytrack.capture_receipt_ingest_v1(bigint,bigint,bigint,text,timestamptz,numeric,text,text,text,jsonb,jsonb)
is 'SPC-001 receipt ingest. Parser facts are immutable capture source; item category/product classification is written only against one transaction projection and Space-local catalog instances.';

commit;
