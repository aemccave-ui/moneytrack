-- MoneyTrack — SPC-001C — capture source / multi-Space projection model
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- A capture_event is shared provenance for one real-world event. Every financial
-- transaction remains owned by exactly one Space. Server read models expose only
-- projections whose Spaces are currently accessible to the actor; no hidden
-- projection count or hidden Space metadata is returned.

begin;

create table if not exists moneytrack.capture_events (
    id bigserial primary key,
    captured_by_user_id bigint references moneytrack.app_users(id) on delete set null,
    source_type text not null check (source_type in ('manual','text','voice','photo_receipt')),
    source_ref text,
    occurred_at timestamptz not null,
    raw_source jsonb not null default '{}'::jsonb,
    legacy_transaction_id bigint unique,
    created_at timestamptz not null default now()
);

create unique index if not exists ux_spc001_capture_source_identity
    on moneytrack.capture_events(captured_by_user_id,source_type,source_ref)
    where captured_by_user_id is not null and source_ref is not null;

alter table moneytrack.transactions
    add column if not exists capture_event_id bigint
        references moneytrack.capture_events(id) on delete set null;

create unique index if not exists ux_spc001_capture_one_projection_per_space
    on moneytrack.transactions(capture_event_id,space_id)
    where capture_event_id is not null and space_id is not null;

create table if not exists moneytrack.capture_receipts (
    id bigserial primary key,
    capture_event_id bigint not null unique
        references moneytrack.capture_events(id) on delete cascade,
    merchant text,
    recognized_at timestamptz,
    total_amount numeric,
    currency text,
    telegram_file_id text,
    receipt_fingerprint text,
    raw_ai_json jsonb not null default '{}'::jsonb,
    legacy_receipt_id bigint unique,
    created_at timestamptz not null default now()
);

create table if not exists moneytrack.capture_receipt_items (
    id bigserial primary key,
    capture_receipt_id bigint not null
        references moneytrack.capture_receipts(id) on delete cascade,
    item_name_original text not null,
    item_language text,
    quantity numeric,
    unit_price numeric,
    amount numeric,
    legacy_receipt_item_id bigint unique,
    created_at timestamptz not null default now()
);

create table if not exists moneytrack.receipt_item_projection_classification (
    transaction_id bigint not null references moneytrack.transactions(id) on delete cascade,
    capture_receipt_item_id bigint not null
        references moneytrack.capture_receipt_items(id) on delete cascade,
    category_id bigint references moneytrack.category_catalog(id) on delete set null,
    product_id bigint references moneytrack.product_catalog(id) on delete set null,
    updated_by_user_id bigint references moneytrack.app_users(id) on delete set null,
    updated_at timestamptz not null default now(),
    primary key(transaction_id,capture_receipt_item_id)
);

-- ---------------------------------------------------------------------------
-- Existing-data migration. Deterministic legacy ids make this idempotent.
-- ---------------------------------------------------------------------------

insert into moneytrack.capture_events(
    captured_by_user_id,source_type,source_ref,occurred_at,raw_source,
    legacy_transaction_id,created_at
)
select
    coalesce(t.created_by_user_id,t.user_id),
    case
      when t.source_type in ('manual','text','voice','photo_receipt') then t.source_type
      when exists (select 1 from moneytrack.receipts r where r.transaction_id=t.id) then 'photo_receipt'
      else 'manual'
    end,
    case when t.source_id is not null then t.source_id::text else 'legacy-tx:'||t.id::text end,
    t.transaction_date,
    jsonb_build_object(
        'legacy_source_type',t.source_type,
        'legacy_source_id',t.source_id
    ),
    t.id,
    coalesce(t.created_at,now())
from moneytrack.transactions t
where t.user_id<>0 or t.space_id is not null
on conflict (legacy_transaction_id) do nothing;

update moneytrack.transactions t
   set capture_event_id=e.id
  from moneytrack.capture_events e
 where e.legacy_transaction_id=t.id
   and t.capture_event_id is null;

insert into moneytrack.capture_receipts(
    capture_event_id,merchant,recognized_at,total_amount,currency,
    telegram_file_id,receipt_fingerprint,raw_ai_json,legacy_receipt_id,created_at
)
select
    t.capture_event_id,
    r.shop_name,
    coalesce(r.receipt_date::timestamptz,t.transaction_date),
    r.total_amount,
    r.currency,
    r.telegram_file_id,
    r.receipt_fingerprint,
    coalesce(r.raw_ai_json,'{}'::jsonb),
    r.id,
    now()
from moneytrack.receipts r
join moneytrack.transactions t on t.id=r.transaction_id
where t.capture_event_id is not null
on conflict (legacy_receipt_id) do nothing;

insert into moneytrack.capture_receipt_items(
    capture_receipt_id,item_name_original,item_language,quantity,unit_price,amount,
    legacy_receipt_item_id,created_at
)
select
    cr.id,ri.item_name_original,ri.item_language,ri.quantity,ri.unit_price,ri.amount,
    ri.id,now()
from moneytrack.receipt_items ri
join moneytrack.receipts r on r.id=ri.receipt_id
join moneytrack.capture_receipts cr on cr.legacy_receipt_id=r.id
on conflict (legacy_receipt_item_id) do nothing;

insert into moneytrack.receipt_item_projection_classification(
    transaction_id,capture_receipt_item_id,category_id,product_id,updated_by_user_id,updated_at
)
select
    r.transaction_id,cri.id,ri.category_id,ri.product_id,
    coalesce(t.updated_by_user_id,t.created_by_user_id,t.user_id),now()
from moneytrack.receipt_items ri
join moneytrack.receipts r on r.id=ri.receipt_id
join moneytrack.transactions t on t.id=r.transaction_id
join moneytrack.capture_receipt_items cri on cri.legacy_receipt_item_id=ri.id
on conflict (transaction_id,capture_receipt_item_id) do nothing;

-- ---------------------------------------------------------------------------
-- Classification relational invariant. The source item must belong to the same
-- capture_event as the projection transaction; category/product must be local to
-- that transaction's Space. No frontend filtering is trusted.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.spc001_assert_receipt_projection_classification_v1()
returns trigger
language plpgsql
as $function$
declare
    v_space_id bigint;
    v_tx_event bigint;
    v_item_event bigint;
    v_ref_space bigint;
begin
    select t.space_id,t.capture_event_id into v_space_id,v_tx_event
      from moneytrack.transactions t where t.id=new.transaction_id;
    if v_space_id is null or v_tx_event is null then
        raise exception 'SPC001_RECEIPT_PROJECTION_TRANSACTION_INVALID' using errcode='23514';
    end if;

    select cr.capture_event_id into v_item_event
      from moneytrack.capture_receipt_items cri
      join moneytrack.capture_receipts cr on cr.id=cri.capture_receipt_id
     where cri.id=new.capture_receipt_item_id;
    if v_item_event is distinct from v_tx_event then
        raise exception 'SPC001_RECEIPT_ITEM_EVENT_MISMATCH' using errcode='23514';
    end if;

    if new.category_id is not null then
        select c.space_id into v_ref_space from moneytrack.category_catalog c where c.id=new.category_id;
        if v_ref_space is distinct from v_space_id then
            raise exception 'SPC001_RECEIPT_CLASSIFICATION_CATEGORY_CROSS_SPACE' using errcode='23514';
        end if;
    end if;

    if new.product_id is not null then
        select p.space_id into v_ref_space from moneytrack.product_catalog p where p.id=new.product_id;
        if v_ref_space is distinct from v_space_id then
            raise exception 'SPC001_RECEIPT_CLASSIFICATION_PRODUCT_CROSS_SPACE' using errcode='23514';
        end if;
    end if;

    return new;
end;
$function$;

drop trigger if exists trg_spc001_receipt_projection_classification
on moneytrack.receipt_item_projection_classification;
create trigger trg_spc001_receipt_projection_classification
before insert or update
on moneytrack.receipt_item_projection_classification
for each row execute function moneytrack.spc001_assert_receipt_projection_classification_v1();

-- ---------------------------------------------------------------------------
-- Create a canonical capture + first projection. This is used by manual/text/
-- voice/photo adapters after their existing authentication boundary.
-- ---------------------------------------------------------------------------

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

    -- Idempotent replay in the same Space returns the existing projection.
    select t.* into v_tx from moneytrack.transactions t
     where t.capture_event_id=v_event_id and t.space_id=p_space_id limit 1;
    if not found then
        v_tx:=moneytrack.finance_create_transaction_space_v1(
            p_actor_user_id,p_space_id,p_account_id,p_transaction_type,
            p_amount_original,p_currency_original,p_description,p_transaction_date,
            p_source_type,null,p_category_id
        );
        update moneytrack.transactions
           set capture_event_id=v_event_id
         where id=v_tx.id;
    end if;

    return query select v_event_id,v_tx.id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Multi-Space posting. Each target supplies Space-local references and may
-- override financial values. Any validation/error aborts the whole function
-- statement, so a multi-target request is atomic: no partial success is returned.
-- ---------------------------------------------------------------------------

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

    -- Actor must already have access to at least one projection of the event.
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

        select t.* into v_tx from moneytrack.transactions t
         where t.capture_event_id=p_capture_event_id and t.space_id=v_space limit 1;
        if found then
            raise exception 'CAPTURE_EVENT_ALREADY_PROJECTED_TO_SPACE' using errcode='23505';
        end if;

        v_tx:=moneytrack.finance_create_transaction_space_v1(
            p_actor_user_id,v_space,v_account,v_type,v_amount,v_currency,
            v_description,v_date,null,null,v_category
        );
        update moneytrack.transactions
           set capture_event_id=p_capture_event_id
         where id=v_tx.id;

        v_rows:=v_rows||jsonb_build_array(jsonb_build_object('space_id',v_space,'transaction_id',v_tx.id));
    end loop;

    return query
    select (x->>'space_id')::bigint,(x->>'transaction_id')::bigint
      from jsonb_array_elements(v_rows) x;
end;
$function$;

comment on function moneytrack.capture_project_multi_v1(bigint,bigint,jsonb)
is 'SPC-001 atomic multi-Space projection boundary. Every target is membership-checked and all account/category references are Space-local; projections are financially independent after creation.';

-- ---------------------------------------------------------------------------
-- Privacy-preserving linkage read. Deliberately omits total projection count and
-- any hidden Space/transaction metadata.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.capture_accessible_projections_v1(
    p_actor_user_id bigint,p_capture_event_id bigint
)
returns table(space_id bigint,transaction_id bigint,space_name text)
language plpgsql
stable
as $function$
begin
    if not exists (
        select 1
        from moneytrack.transactions visible
        join moneytrack.workspace_members vm
          on vm.workspace_id=visible.space_id
         and vm.user_id=p_actor_user_id
         and coalesce(vm.is_active,true)=true
        join moneytrack.workspaces vw
          on vw.id=visible.space_id and coalesce(vw.is_active,true)=true
        where visible.capture_event_id=p_capture_event_id
    ) then
        raise exception 'CAPTURE_EVENT_NOT_FOUND_OR_NOT_ACCESSIBLE' using errcode='P0002';
    end if;

    return query
    select t.space_id,t.id,w.name
    from moneytrack.transactions t
    join moneytrack.workspace_members wm
      on wm.workspace_id=t.space_id
     and wm.user_id=p_actor_user_id
     and coalesce(wm.is_active,true)=true
    join moneytrack.workspaces w
      on w.id=t.space_id
     and coalesce(w.is_active,true)=true
    where t.capture_event_id=p_capture_event_id
    order by t.id;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Projection-specific receipt classification + read model.
-- ---------------------------------------------------------------------------

create or replace function moneytrack.receipt_projection_set_classification_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_transaction_id bigint,
    p_capture_receipt_item_id bigint,
    p_category_id bigint,
    p_product_id bigint default null
)
returns text
language plpgsql
volatile
as $function$
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);
    if not exists (
        select 1 from moneytrack.transactions t
        where t.id=p_transaction_id and t.space_id=p_space_id and t.capture_event_id is not null
    ) then raise exception 'TRANSACTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    if p_category_id is not null and not exists (
        select 1 from moneytrack.category_catalog c
        where c.id=p_category_id and c.space_id=p_space_id and coalesce(c.is_active,true)=true
    ) then raise exception 'CATEGORY_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    if p_product_id is not null and not exists (
        select 1 from moneytrack.product_catalog p
        where p.id=p_product_id and p.space_id=p_space_id and coalesce(p.is_active,true)=true
    ) then raise exception 'PRODUCT_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;

    insert into moneytrack.receipt_item_projection_classification(
        transaction_id,capture_receipt_item_id,category_id,product_id,updated_by_user_id,updated_at
    ) values (
        p_transaction_id,p_capture_receipt_item_id,p_category_id,p_product_id,p_actor_user_id,now()
    )
    on conflict (transaction_id,capture_receipt_item_id) do update
       set category_id=excluded.category_id,
           product_id=excluded.product_id,
           updated_by_user_id=excluded.updated_by_user_id,
           updated_at=now();

    return 'updated';
end;
$function$;

create or replace function moneytrack.receipt_projection_read_v1(
    p_actor_user_id bigint,p_space_id bigint,p_transaction_id bigint
)
returns jsonb
language plpgsql
stable
as $function$
declare v_result jsonb;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select jsonb_build_object(
        'transaction_id',t.id,
        'space_id',t.space_id,
        'merchant',cr.merchant,
        'recognized_at',cr.recognized_at,
        'total_amount',cr.total_amount,
        'currency',cr.currency,
        'items',coalesce((
            select jsonb_agg(jsonb_build_object(
                'receipt_item_id',cri.id,
                'item_name_original',cri.item_name_original,
                'item_language',cri.item_language,
                'quantity',cri.quantity,
                'unit_price',cri.unit_price,
                'amount',cri.amount,
                'category_id',pc.category_id,
                'product_id',pc.product_id
            ) order by cri.id)
            from moneytrack.capture_receipt_items cri
            left join moneytrack.receipt_item_projection_classification pc
              on pc.transaction_id=t.id and pc.capture_receipt_item_id=cri.id
            where cri.capture_receipt_id=cr.id
        ),'[]'::jsonb)
    ) into v_result
    from moneytrack.transactions t
    join moneytrack.capture_receipts cr on cr.capture_event_id=t.capture_event_id
    where t.id=p_transaction_id and t.space_id=p_space_id;

    if v_result is null then raise exception 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002'; end if;
    return v_result;
end;
$function$;

comment on table moneytrack.receipt_item_projection_classification
is 'SPC-001 receipt classification is projection-specific: transaction_id + immutable source receipt item + Space-local category/product.';

-- Legacy receipt_items.category_id/product_id are compatibility fields for the
-- original projection only and are no longer the canonical classification source.

commit;
