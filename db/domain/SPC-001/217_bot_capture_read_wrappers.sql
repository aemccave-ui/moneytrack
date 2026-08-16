-- MoneyTrack — SPC-001C — Bot capture read-only compatibility wrappers
-- SOURCE ONLY until controlled runtime apply.
--
-- Keeps n8n thin while preserving the existing Bot photo UX: exact duplicate
-- short-circuit before OCR, semantic duplicate check after parsing, localized
-- Space categories for AI assignment, and projection-specific uncategorized
-- product discovery. Hidden Space projections are never observable.

begin;

create or replace function moneytrack.capture_receipt_duplicate_probe_v1(
    p_actor_user_id bigint,
    p_telegram_file_id text default null,
    p_receipt_fingerprint text default null
)
returns table(
    duplicate_found boolean,
    semantic_duplicate_found boolean,
    duplicate_receipt_id bigint,
    status text
)
language plpgsql
stable
as $function$
declare
    v_file text:=nullif(btrim(p_telegram_file_id),'');
    v_fingerprint text:=nullif(btrim(p_receipt_fingerprint),'');
    v_duplicate bigint;
begin
    if p_actor_user_id is null then
        raise exception 'ACTOR_REQUIRED' using errcode='22023';
    end if;
    if not exists(select 1 from moneytrack.app_users u where u.id=p_actor_user_id) then
        raise exception 'ACTOR_NOT_FOUND' using errcode='P0002';
    end if;

    if v_file is not null then
        select cr.id into v_duplicate
          from moneytrack.capture_receipts cr
          join moneytrack.capture_events e on e.id=cr.capture_event_id
         where e.captured_by_user_id=p_actor_user_id
           and cr.telegram_file_id=v_file
           and exists (
               select 1
                 from moneytrack.transactions t
                 join moneytrack.workspace_members wm
                   on wm.workspace_id=t.space_id
                  and wm.user_id=p_actor_user_id
                  and coalesce(wm.is_active,true)=true
                 join moneytrack.workspaces w
                   on w.id=t.space_id
                  and coalesce(w.is_active,true)=true
                where t.capture_event_id=e.id
           )
         order by cr.id desc
         limit 1;

        if v_duplicate is not null then
            return query select true,false,v_duplicate,'duplicate_exact'::text;
            return;
        end if;
    end if;

    if v_fingerprint is not null then
        select cr.id into v_duplicate
          from moneytrack.capture_receipts cr
          join moneytrack.capture_events e on e.id=cr.capture_event_id
         where e.captured_by_user_id=p_actor_user_id
           and cr.receipt_fingerprint=v_fingerprint
           and exists (
               select 1
                 from moneytrack.transactions t
                 join moneytrack.workspace_members wm
                   on wm.workspace_id=t.space_id
                  and wm.user_id=p_actor_user_id
                  and coalesce(wm.is_active,true)=true
                 join moneytrack.workspaces w
                   on w.id=t.space_id
                  and coalesce(w.is_active,true)=true
                where t.capture_event_id=e.id
           )
         order by cr.id desc
         limit 1;

        if v_duplicate is not null then
            return query select false,true,v_duplicate,'duplicate_semantic'::text;
            return;
        end if;
    end if;

    return query select false,false,null::bigint,'new'::text;
end;
$function$;

comment on function moneytrack.capture_receipt_duplicate_probe_v1(bigint,text,text)
is 'SPC-001 read-only receipt duplicate probe. Exact/semantic identities are observable only when the actor currently has an active membership projection of the capture.';


create or replace function moneytrack.capture_categories_space_read_v1(
    p_actor_user_id bigint,
    p_space_id bigint
)
returns table(
    id bigint,
    code text,
    name text
)
language plpgsql
stable
as $function$
declare v_language text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select coalesce(us.language_code,u.language_code,'en')
      into v_language
      from moneytrack.app_users u
      left join moneytrack.user_settings us on us.user_id=u.id
     where u.id=p_actor_user_id;

    return query
    select c.id,c.code,coalesce(tr.name,c.code)
      from moneytrack.category_catalog c
      left join moneytrack.category_catalog_translations tr
        on tr.category_id=c.id
       and tr.language_code=v_language
     where c.space_id=p_space_id
       and coalesce(c.is_active,true)=true
     order by c.sort_order,c.id;
end;
$function$;

comment on function moneytrack.capture_categories_space_read_v1(bigint,bigint)
is 'SPC-001 localized active category rows for Bot/AI capture classification in exactly one authorized Space.';


create or replace function moneytrack.receipt_projection_uncategorized_products_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_capture_receipt_id bigint
)
returns table(
    products jsonb,
    uncategorized_count integer
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
    with product_rows as (
        select distinct
            pc.id as product_id,
            pc.product_key,
            pc.original_name,
            pc.original_language
          from moneytrack.capture_receipt_items cri
          join moneytrack.receipt_item_projection_classification ric
            on ric.transaction_id=v_transaction_id
           and ric.capture_receipt_item_id=cri.id
          join moneytrack.product_catalog pc
            on pc.id=ric.product_id
           and pc.space_id=p_space_id
         where cri.capture_receipt_id=p_capture_receipt_id
           and ric.category_id is null
           and coalesce(pc.is_active,true)=true
    )
    select
        coalesce(jsonb_agg(jsonb_build_object(
            'product_id',p.product_id,
            'product_key',p.product_key,
            'original_name',p.original_name,
            'original_language',p.original_language
        ) order by p.product_id),'[]'::jsonb),
        count(*)::integer
      from product_rows p;
end;
$function$;

comment on function moneytrack.receipt_projection_uncategorized_products_v1(bigint,bigint,bigint)
is 'SPC-001 projection-specific uncategorized product list for receipt AI assignment. It cannot read another Space projection.';

commit;
