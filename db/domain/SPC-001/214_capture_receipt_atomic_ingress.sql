-- MoneyTrack — SPC-001C — atomic receipt capture/projection ingress
-- SOURCE ONLY until controlled runtime apply.
--
-- Preserves BE-DOM-002 duplicate serialization/return contract while ensuring
-- duplicate discovery never leaks a capture whose projections are all currently
-- inaccessible to the actor. New receipt + transaction projection + immutable
-- source items/classifications are committed atomically in one backend call.

begin;

create or replace function moneytrack.capture_receipt_ingest_projection_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_source_ref text,
    p_account_id bigint,
    p_total_amount numeric,
    p_currency text,
    p_shop_name text,
    p_recognized_at timestamptz,
    p_telegram_file_id text,
    p_receipt_fingerprint text,
    p_raw_ai_json jsonb,
    p_items jsonb
)
returns table(
    status text,
    transaction_id bigint,
    receipt_id bigint,
    created_item_count integer,
    duplicate_receipt_id bigint,
    capture_event_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_duplicate_id bigint;
    v_projection record;
    v_receipt jsonb;
    v_created_count integer := 0;
    v_file text:=nullif(btrim(p_telegram_file_id),'');
    v_fingerprint text:=nullif(btrim(p_receipt_fingerprint),'');
    v_source_ref text:=nullif(btrim(p_source_ref),'');
    v_recognized timestamptz:=coalesce(p_recognized_at,current_timestamp);
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if v_source_ref is null then
        raise exception 'CAPTURE_SOURCE_REF_REQUIRED' using errcode='22023';
    end if;
    if p_account_id is null then
        raise exception 'ACCOUNT_REQUIRED' using errcode='22023';
    end if;
    if p_total_amount is null or p_total_amount<=0 then
        raise exception 'INVALID_RECEIPT_TOTAL' using errcode='22023';
    end if;
    if p_currency is null or btrim(p_currency)='' then
        raise exception 'CURRENCY_REQUIRED' using errcode='22023';
    end if;
    if p_items is null or jsonb_typeof(p_items)<>'array' then
        raise exception 'ITEMS_ARRAY_REQUIRED' using errcode='22023';
    end if;

    -- Same race-closure idea as BE-DOM-002, now actor/capture scoped.
    if v_file is not null then
        perform pg_advisory_xact_lock(
            hashtextextended('SPC-001:receipt-file:'||p_actor_user_id::text||':'||v_file,0)
        );
    end if;
    if v_fingerprint is not null then
        perform pg_advisory_xact_lock(
            hashtextextended('SPC-001:receipt-fingerprint:'||p_actor_user_id::text||':'||v_fingerprint,0)
        );
    end if;

    -- Privacy rule: a duplicate source is observable only if the actor currently
    -- has at least one active membership projection of that capture. A removed
    -- member cannot infer hidden Space existence through a fingerprint response.
    if v_file is not null then
        select cr.id into v_duplicate_id
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

        if v_duplicate_id is not null then
            return query
            select 'duplicate_exact'::text,null::bigint,null::bigint,0::integer,v_duplicate_id,null::bigint;
            return;
        end if;
    end if;

    if v_fingerprint is not null then
        select cr.id into v_duplicate_id
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

        if v_duplicate_id is not null then
            return query
            select 'duplicate_semantic'::text,null::bigint,null::bigint,0::integer,v_duplicate_id,null::bigint;
            return;
        end if;
    end if;

    select * into v_projection
      from moneytrack.capture_create_projection_compat_v1(
          p_actor_user_id,
          p_space_id,
          'photo_receipt',
          v_source_ref,
          p_account_id,
          'expense',
          p_total_amount,
          upper(p_currency),
          nullif(btrim(p_shop_name),''),
          v_recognized,
          null
      );

    -- A source_ref replay without file/fingerprint metadata is still idempotent.
    if v_projection.idempotent_replay then
        select cr.id into v_duplicate_id
          from moneytrack.capture_receipts cr
         where cr.capture_event_id=v_projection.capture_event_id
         limit 1;
        if v_duplicate_id is not null then
            return query
            select 'duplicate_exact'::text,null::bigint,null::bigint,0::integer,v_duplicate_id,v_projection.capture_event_id;
            return;
        end if;
    end if;

    v_receipt:=moneytrack.capture_receipt_ingest_v1(
        p_actor_user_id,
        p_space_id,
        v_projection.id,
        nullif(btrim(p_shop_name),''),
        v_recognized,
        p_total_amount,
        upper(p_currency),
        v_file,
        v_fingerprint,
        coalesce(p_raw_ai_json,'{}'::jsonb),
        p_items
    );

    v_created_count:=coalesce(jsonb_array_length(v_receipt->'items'),0);

    return query
    select
        'created'::text,
        v_projection.id,
        (v_receipt->>'receipt_id')::bigint,
        v_created_count,
        null::bigint,
        v_projection.capture_event_id;
end;
$function$;

comment on function moneytrack.capture_receipt_ingest_projection_v1(bigint,bigint,text,bigint,numeric,text,text,timestamptz,text,text,jsonb,jsonb)
is 'SPC-001 atomic photo ingress. Duplicate exact/semantic checks are serialized and privacy-filtered; otherwise one transaction projection and immutable capture receipt are created atomically.';

commit;
