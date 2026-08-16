-- MoneyTrack — SPC-001C — capture projection source-identity hardening
--
-- Corrects the initial 210 functions so hardened BE-DOM-001 source identity is
-- always complete. New projections use (source_type, capture_event_id) as the
-- per-Space idempotency identity; capture_event remains the cross-Space source.

begin;

create or replace function moneytrack.capture_create_projection_v1(
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
    p_category_id bigint default null,
    p_raw_source jsonb default '{}'::jsonb
)
returns table(capture_event_id bigint,transaction_id bigint)
language plpgsql
volatile
as $function$
declare
    v_event_id bigint;
    v_tx moneytrack.transactions%rowtype;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if p_source_type not in ('manual','text','voice','photo_receipt') then
        raise exception 'CAPTURE_SOURCE_INVALID' using errcode='22023';
    end if;

    if p_source_ref is not null then
        select e.id into v_event_id
          from moneytrack.capture_events e
         where e.captured_by_user_id=p_actor_user_id
           and e.source_type=p_source_type
           and e.source_ref=p_source_ref
         limit 1;
    end if;

    if v_event_id is null then
        insert into moneytrack.capture_events(
            captured_by_user_id,source_type,source_ref,occurred_at,raw_source,created_at
        ) values (
            p_actor_user_id,p_source_type,p_source_ref,p_transaction_date,
            coalesce(p_raw_source,'{}'::jsonb),now()
        ) returning id into v_event_id;
    end if;

    select t.* into v_tx
      from moneytrack.transactions t
     where t.capture_event_id=v_event_id and t.space_id=p_space_id
     limit 1;

    if not found then
        v_tx:=moneytrack.finance_create_transaction_space_v1(
            p_actor_user_id,p_space_id,p_account_id,p_transaction_type,
            p_amount_original,p_currency_original,p_description,p_transaction_date,
            p_source_type,v_event_id,p_category_id
        );
        update moneytrack.transactions
           set capture_event_id=v_event_id
         where id=v_tx.id;
    end if;

    return query select v_event_id,v_tx.id;
end;
$function$;

create or replace function moneytrack.capture_project_multi_v1(
    p_actor_user_id bigint,
    p_capture_event_id bigint,
    p_targets jsonb
)
returns table(space_id bigint,transaction_id bigint)
language plpgsql
volatile
as $function$
declare
    v_source moneytrack.transactions%rowtype;
    v_event_source_type text;
    v_target jsonb;
    v_space bigint;
    v_account bigint;
    v_category bigint;
    v_amount numeric;
    v_currency text;
    v_description text;
    v_date timestamptz;
    v_type text;
    v_tx moneytrack.transactions%rowtype;
    v_rows jsonb:='[]'::jsonb;
begin
    if p_targets is null or jsonb_typeof(p_targets)<>'array' or jsonb_array_length(p_targets)=0 then
        raise exception 'MULTI_SPACE_TARGETS_REQUIRED' using errcode='22023';
    end if;

    select e.source_type into v_event_source_type
      from moneytrack.capture_events e
     where e.id=p_capture_event_id;
    if v_event_source_type is null then
        raise exception 'CAPTURE_EVENT_NOT_FOUND_OR_NOT_ACCESSIBLE' using errcode='P0002';
    end if;

    -- Actor must have at least one currently accessible projection. Knowing or
    -- guessing a capture_event_id is never sufficient authorization.
    select t.* into v_source
      from moneytrack.transactions t
      join moneytrack.workspace_members wm
        on wm.workspace_id=t.space_id
       and wm.user_id=p_actor_user_id
       and coalesce(wm.is_active,true)=true
      join moneytrack.workspaces w
        on w.id=t.space_id and coalesce(w.is_active,true)=true
     where t.capture_event_id=p_capture_event_id
     order by t.id
     limit 1;
    if not found then
        raise exception 'CAPTURE_EVENT_NOT_FOUND_OR_NOT_ACCESSIBLE' using errcode='P0002';
    end if;

    for v_target in select value from jsonb_array_elements(p_targets)
    loop
        v_space:=nullif(v_target->>'space_id','')::bigint;
        v_account:=nullif(v_target->>'account_id','')::bigint;
        v_category:=nullif(v_target->>'category_id','')::bigint;
        v_amount:=coalesce(nullif(v_target->>'amount_original','')::numeric,v_source.amount_original);
        v_currency:=coalesce(nullif(v_target->>'currency_original',''),v_source.currency_original);
        v_description:=coalesce(v_target->>'description',v_source.description);
        v_date:=coalesce(nullif(v_target->>'transaction_date','')::timestamptz,v_source.transaction_date);
        v_type:=coalesce(nullif(v_target->>'transaction_type',''),v_source.transaction_type);

        perform moneytrack.assert_space_member_v1(p_actor_user_id,v_space);

        if v_account is null or not exists (
            select 1 from moneytrack.accounts a
            where a.id=v_account and a.space_id=v_space and coalesce(a.is_active,true)=true
        ) then raise exception 'ACCOUNT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

        if v_category is not null and not exists (
            select 1 from moneytrack.category_catalog c
            where c.id=v_category and c.space_id=v_space and coalesce(c.is_active,true)=true
        ) then raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

        if exists (
            select 1 from moneytrack.transactions t
            where t.capture_event_id=p_capture_event_id and t.space_id=v_space
        ) then
            raise exception 'CAPTURE_EVENT_ALREADY_PROJECTED_TO_SPACE' using errcode='23505';
        end if;

        v_tx:=moneytrack.finance_create_transaction_space_v1(
            p_actor_user_id,v_space,v_account,v_type,v_amount,v_currency,
            v_description,v_date,v_event_source_type,p_capture_event_id,v_category
        );

        update moneytrack.transactions
           set capture_event_id=p_capture_event_id
         where id=v_tx.id;

        v_rows:=v_rows||jsonb_build_array(
            jsonb_build_object('space_id',v_space,'transaction_id',v_tx.id)
        );
    end loop;

    return query
    select (x->>'space_id')::bigint,(x->>'transaction_id')::bigint
      from jsonb_array_elements(v_rows) x;
end;
$function$;

comment on function moneytrack.capture_project_multi_v1(bigint,bigint,jsonb)
is 'SPC-001 atomic multi-Space projection. Source identity is complete and deterministic: event source_type + capture_event_id, scoped by target Space.';

commit;
