-- MoneyTrack — SPC-001C — projection-specific receipt category assignment
-- SOURCE ONLY until controlled runtime apply.
--
-- Preserves the accepted BE-DOM-002 AI/manual assignment semantics while moving
-- ownership from user_id to Space. Product defaults are Space-local; receipt item
-- classifications are always specific to one transaction projection.

begin;

create or replace function moneytrack.receipt_projection_assign_categories_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_capture_receipt_id bigint,
    p_assignments jsonb
)
returns table(
    status text,
    updated_product_count integer,
    updated_item_count integer
)
language plpgsql
volatile
as $function$
declare
    v_transaction_id bigint;
    v_product_count integer := 0;
    v_item_count integer := 0;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if p_capture_receipt_id is null then
        raise exception 'RECEIPT_REQUIRED' using errcode='22023';
    end if;
    if p_assignments is null or jsonb_typeof(p_assignments)<>'array' then
        raise exception 'ASSIGNMENTS_ARRAY_REQUIRED' using errcode='22023';
    end if;

    select t.id into v_transaction_id
      from moneytrack.capture_receipts cr
      join moneytrack.transactions t
        on t.capture_event_id=cr.capture_event_id
       and t.space_id=p_space_id
     where cr.id=p_capture_receipt_id
     limit 1;

    if v_transaction_id is null then
        raise exception 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    -- Reject malformed or foreign references rather than silently discarding them.
    if exists (
        select 1
        from jsonb_to_recordset(p_assignments)
             as x(product_id bigint,category_id bigint)
        where x.product_id is null
           or x.category_id is null
           or not exists (
               select 1 from moneytrack.product_catalog pc
               where pc.id=x.product_id and pc.space_id=p_space_id and coalesce(pc.is_active,true)=true
           )
           or not exists (
               select 1 from moneytrack.category_catalog cc
               where cc.id=x.category_id and cc.space_id=p_space_id and coalesce(cc.is_active,true)=true
           )
           or not exists (
               select 1
               from moneytrack.receipt_item_projection_classification ric
               where ric.transaction_id=v_transaction_id
                 and ric.product_id=x.product_id
           )
    ) then
        raise exception 'RECEIPT_ASSIGNMENT_FOREIGN_OR_INVALID' using errcode='22023';
    end if;

    with assignments as (
        select distinct x.product_id,x.category_id
        from jsonb_to_recordset(p_assignments)
             as x(product_id bigint,category_id bigint)
    ), updated as (
        update moneytrack.product_catalog pc
           set category_id=a.category_id,
               updated_by_user_id=p_actor_user_id
          from assignments a
         where pc.id=a.product_id
           and pc.space_id=p_space_id
        returning pc.id
    )
    select count(*)::integer into v_product_count from updated;

    with assignments as (
        select distinct x.product_id,x.category_id
        from jsonb_to_recordset(p_assignments)
             as x(product_id bigint,category_id bigint)
    ), updated as (
        update moneytrack.receipt_item_projection_classification ric
           set category_id=a.category_id,
               updated_by_user_id=p_actor_user_id,
               updated_at=now()
          from assignments a
         where ric.transaction_id=v_transaction_id
           and ric.product_id=a.product_id
           and ric.category_id is null
        returning ric.capture_receipt_item_id
    )
    select count(*)::integer into v_item_count from updated;

    return query select
        case when v_product_count>0 then 'updated' else 'no_match' end::text,
        v_product_count,
        v_item_count;
end;
$function$;

comment on function moneytrack.receipt_projection_assign_categories_v1(bigint,bigint,bigint,jsonb)
is 'SPC-001 AI assignment boundary. Validates product/category in one Space, updates the Space-local product default, and propagates only into uncategorized items of the selected transaction projection.';


create or replace function moneytrack.receipt_projection_set_item_category_hint_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_capture_receipt_item_id bigint,
    p_category_hint text
)
returns table(
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
    v_transaction_id bigint;
    v_item_name text;
    v_product_id bigint;
    v_category_id bigint;
    v_category_code text;
    v_category_name text;
    v_normalized_hint text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if p_capture_receipt_item_id is null
       or p_category_hint is null
       or btrim(p_category_hint)=''
    then
        return query
        select p_capture_receipt_item_id,p_category_hint,null::text,null::bigint,
               null::bigint,null::text,null::text,'invalid_command'::text;
        return;
    end if;

    select coalesce(us.language_code,u.language_code,'en')
      into v_language_code
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id=u.id
     where u.id=p_actor_user_id;

    select t.id,cri.item_name_original,ric.product_id
      into v_transaction_id,v_item_name,v_product_id
      from moneytrack.capture_receipt_items cri
      join moneytrack.capture_receipts cr on cr.id=cri.capture_receipt_id
      join moneytrack.transactions t
        on t.capture_event_id=cr.capture_event_id
       and t.space_id=p_space_id
      left join moneytrack.receipt_item_projection_classification ric
        on ric.transaction_id=t.id
       and ric.capture_receipt_item_id=cri.id
     where cri.id=p_capture_receipt_item_id
     limit 1;

    if v_transaction_id is null then
        return query
        select p_capture_receipt_item_id,p_category_hint,null::text,null::bigint,
               null::bigint,null::text,null::text,'item_not_found'::text;
        return;
    end if;

    v_normalized_hint:=lower(
        regexp_replace(p_category_hint,'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g')
    );

    select c.id,c.code,coalesce(tr.name,c.code)
      into v_category_id,v_category_code,v_category_name
      from moneytrack.category_catalog c
      left join moneytrack.category_catalog_translations tr
        on tr.category_id=c.id
       and tr.language_code=v_language_code
     where c.space_id=p_space_id
       and coalesce(c.is_active,true)=true
       and (
            lower(c.code)=lower(p_category_hint)
         or lower(c.code) like '%'||lower(p_category_hint)||'%'
         or lower(coalesce(tr.name,''))=lower(p_category_hint)
         or lower(regexp_replace(coalesce(tr.name,''),'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_normalized_hint
         or lower(regexp_replace(coalesce(tr.name,''),'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g')) like '%'||v_normalized_hint||'%'
       )
     order by
       case
         when lower(c.code)=lower(p_category_hint) then 0
         when lower(coalesce(tr.name,''))=lower(p_category_hint) then 1
         when lower(regexp_replace(coalesce(tr.name,''),'[^a-zA-Zа-яА-ЯёЁ0-9]+','','g'))=v_normalized_hint then 2
         when lower(c.code) like '%'||lower(p_category_hint)||'%' then 3
         else 4
       end,
       length(c.code) desc,
       length(coalesce(tr.name,c.code))
     limit 1;

    if v_category_id is null then
        return query
        select p_capture_receipt_item_id,p_category_hint,v_item_name,v_product_id,
               null::bigint,null::text,null::text,'category_not_found'::text;
        return;
    end if;

    perform moneytrack.receipt_projection_set_classification_v1(
        p_actor_user_id,p_space_id,v_transaction_id,p_capture_receipt_item_id,
        v_category_id,v_product_id
    );

    if v_product_id is not null then
        update moneytrack.product_catalog pc
           set category_id=v_category_id,
               updated_by_user_id=p_actor_user_id
         where pc.id=v_product_id
           and pc.space_id=p_space_id;
    end if;

    return query
    select p_capture_receipt_item_id,p_category_hint,v_item_name,v_product_id,
           v_category_id,v_category_code,v_category_name,'updated'::text;
end;
$function$;

comment on function moneytrack.receipt_projection_set_item_category_hint_v1(bigint,bigint,bigint,text)
is 'SPC-001 manual item-category boundary. Preserves legacy code/translation hint matching inside the requested Space and mutates only that receipt projection plus its Space-local product default.';


create or replace function moneytrack.receipt_projection_product_item_read_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_capture_receipt_id bigint,
    p_item_name text,
    p_quantity numeric,
    p_unit_price numeric,
    p_amount numeric
)
returns table(
    receipt_item_id bigint,
    product_id bigint,
    category_id bigint,
    item_name_original text,
    quantity numeric,
    unit_price numeric,
    amount numeric
)
language plpgsql
stable
as $function$
declare v_transaction_id bigint;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select t.id into v_transaction_id
      from moneytrack.capture_receipts cr
      join moneytrack.transactions t
        on t.capture_event_id=cr.capture_event_id
       and t.space_id=p_space_id
     where cr.id=p_capture_receipt_id
     limit 1;

    if v_transaction_id is null then
        raise exception 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    return query
    select
        cri.id,
        ric.product_id,
        ric.category_id,
        cri.item_name_original,
        cri.quantity,
        cri.unit_price,
        cri.amount
    from moneytrack.capture_receipt_items cri
    join moneytrack.capture_receipts cr on cr.id=cri.capture_receipt_id
    left join moneytrack.receipt_item_projection_classification ric
      on ric.transaction_id=v_transaction_id
     and ric.capture_receipt_item_id=cri.id
    where cr.id=p_capture_receipt_id
      and cri.item_name_original=coalesce(p_item_name,cri.item_name_original)
      and cri.quantity is not distinct from p_quantity
      and cri.unit_price is not distinct from p_unit_price
      and cri.amount is not distinct from p_amount
    order by cri.id
    limit 1;
end;
$function$;

commit;
