-- MoneyTrack — SPC-001D — controlled legacy reference repair fragment
--
-- TRANSACTION BODY ONLY. Injected by spc001-build-db-migration.py inside the
-- 010 tenancy migration after Personal Spaces/space_id are assigned and before
-- its same-Space reconciliation. It severs historical cross-user references by
-- reusing an equivalent target-Space code when present or by creating the
-- minimum private shadow-copy path required by the legacy rows.
--
-- No foreign source user id is retained on a shadow copy. The durable object is
-- owned by the target Personal Space; source->clone provenance exists only in
-- these temporary migration ledgers and disappears at COMMIT.

create temporary table spc001_legacy_reference_clones (
    kind text not null check (kind in ('account','category')),
    source_id bigint not null,
    target_user_id bigint not null,
    target_space_id bigint not null,
    new_id bigint not null,
    source_code text not null,
    primary key (kind, source_id, target_space_id),
    unique (kind, new_id)
) on commit drop;

create temporary table spc001_legacy_reference_repairs (
    kind text not null check (kind in (
        'transaction_account','receipt_item_category','product_category','budget_category'
    )),
    row_id bigint not null,
    old_target_id bigint not null,
    new_target_id bigint not null,
    target_user_id bigint not null,
    target_space_id bigint not null,
    primary key (kind, row_id)
) on commit drop;

create temporary table spc001_account_reference_map (
    source_id bigint not null,
    target_user_id bigint not null,
    target_space_id bigint not null,
    target_id bigint not null,
    primary key (source_id, target_space_id)
) on commit drop;

create temporary table spc001_category_reference_map (
    source_id bigint not null,
    target_user_id bigint not null,
    target_space_id bigint not null,
    target_id bigint not null,
    primary key (source_id, target_space_id)
) on commit drop;

-- ---------------------------------------------------------------------------
-- Account paths required by cross-Space transaction/account references.
-- Ancestors are resolved root-first so a cloned child always points at a local
-- parent. 308_migration_reference_repairability_preflight.sql proves acyclicity,
-- same-owner source paths, candidate uniqueness and candidate compatibility.
-- ---------------------------------------------------------------------------

do $repair_account_paths$
declare
    r record;
    v_target_id bigint;
    v_parent_target_id bigint;
begin
    for r in
        with recursive seeds as (
            select distinct
                t.user_id as target_user_id,
                t.space_id as target_space_id,
                a.id as source_id
            from moneytrack.transactions t
            join moneytrack.accounts a on a.id=t.account_id
            where t.space_id is distinct from a.space_id
        ), path as (
            select
                s.target_user_id,
                s.target_space_id,
                a.id as source_id,
                a.parent_id,
                a.code,
                a.name,
                a.account_type,
                a.currency_code,
                a.is_active,
                a.created_at,
                a.sort_order,
                0::integer as depth
            from seeds s
            join moneytrack.accounts a on a.id=s.source_id
            union all
            select
                p.target_user_id,
                p.target_space_id,
                parent.id,
                parent.parent_id,
                parent.code,
                parent.name,
                parent.account_type,
                parent.currency_code,
                parent.is_active,
                parent.created_at,
                parent.sort_order,
                p.depth+1
            from path p
            join moneytrack.accounts parent on parent.id=p.parent_id
        ), dedup as (
            select
                target_user_id,target_space_id,source_id,
                max(depth) as depth,
                min(parent_id) as parent_id,
                min(code) as code,
                min(name) as name,
                min(account_type::text) as account_type,
                min(currency_code) as currency_code,
                bool_and(coalesce(is_active,true)) as is_active,
                min(created_at) as created_at,
                min(sort_order) as sort_order
            from path
            group by target_user_id,target_space_id,source_id
        )
        select * from dedup
        order by target_space_id, depth desc, source_id
    loop
        v_parent_target_id := null;
        if r.parent_id is not null then
            select m.target_id into v_parent_target_id
            from spc001_account_reference_map m
            where m.source_id=r.parent_id
              and m.target_space_id=r.target_space_id;
            if v_parent_target_id is null then
                raise exception 'SPC001_ACCOUNT_REPAIR_PARENT_NOT_MAPPED: source=% target_space=%',
                    r.source_id,r.target_space_id;
            end if;
        end if;

        select a.id into v_target_id
        from moneytrack.accounts a
        where a.space_id=r.target_space_id
          and a.code is not distinct from r.code
        limit 1;

        if v_target_id is null then
            insert into moneytrack.accounts(
                user_id,space_id,code,name,account_type,currency_code,
                is_active,created_at,sort_order,parent_id,
                created_by_user_id,updated_by_user_id
            ) values (
                r.target_user_id,r.target_space_id,r.code,r.name,r.account_type,r.currency_code,
                r.is_active,coalesce(r.created_at,now()),r.sort_order,v_parent_target_id,
                r.target_user_id,r.target_user_id
            ) returning id into v_target_id;

            insert into spc001_legacy_reference_clones(
                kind,source_id,target_user_id,target_space_id,new_id,source_code
            ) values (
                'account',r.source_id,r.target_user_id,r.target_space_id,v_target_id,r.code
            );
        end if;

        insert into spc001_account_reference_map(
            source_id,target_user_id,target_space_id,target_id
        ) values (
            r.source_id,r.target_user_id,r.target_space_id,v_target_id
        ) on conflict (source_id,target_space_id) do update
          set target_id=excluded.target_id,
              target_user_id=excluded.target_user_id;
    end loop;
end;
$repair_account_paths$;

insert into spc001_legacy_reference_repairs(
    kind,row_id,old_target_id,new_target_id,target_user_id,target_space_id
)
select
    'transaction_account',t.id,t.account_id,m.target_id,t.user_id,t.space_id
from moneytrack.transactions t
join spc001_account_reference_map m
  on m.source_id=t.account_id
 and m.target_space_id=t.space_id
where t.account_id is distinct from m.target_id;

update moneytrack.transactions t
set account_id=r.new_target_id
from spc001_legacy_reference_repairs r
where r.kind='transaction_account'
  and r.row_id=t.id
  and t.account_id=r.old_target_id;

-- ---------------------------------------------------------------------------
-- Category paths required by receipt-item/product/budget references.
-- Existing owner-local codes win. Missing paths are cloned root-first, including
-- localized names, while the clone itself contains no durable foreign linkage.
-- ---------------------------------------------------------------------------

do $repair_category_paths$
declare
    r record;
    v_target_id bigint;
    v_parent_target_id bigint;
    v_created boolean;
begin
    for r in
        with recursive seeds as (
            select distinct r.user_id as target_user_id,r.space_id as target_space_id,c.id as source_id
            from moneytrack.receipt_items ri
            join moneytrack.receipts r on r.id=ri.receipt_id
            join moneytrack.category_catalog c on c.id=ri.category_id
            where ri.category_id is not null and r.space_id is distinct from c.space_id
            union
            select distinct p.user_id,p.space_id,c.id
            from moneytrack.product_catalog p
            join moneytrack.category_catalog c on c.id=p.category_id
            where p.category_id is not null and p.space_id is distinct from c.space_id
            union
            select distinct b.user_id,b.space_id,c.id
            from moneytrack.budget_rules b
            join moneytrack.category_catalog c on c.id=b.category_id
            where b.category_id is not null and b.space_id is distinct from c.space_id
        ), path as (
            select
                s.target_user_id,s.target_space_id,c.id as source_id,c.parent_id,
                c.code,c.is_active,c.sort_order,c.created_at,
                c.show_in_budget_report,c.budget_sort_order,c.flow_type,
                0::integer as depth
            from seeds s
            join moneytrack.category_catalog c on c.id=s.source_id
            union all
            select
                p.target_user_id,p.target_space_id,parent.id,parent.parent_id,
                parent.code,parent.is_active,parent.sort_order,parent.created_at,
                parent.show_in_budget_report,parent.budget_sort_order,parent.flow_type,
                p.depth+1
            from path p
            join moneytrack.category_catalog parent on parent.id=p.parent_id
        ), dedup as (
            select
                target_user_id,target_space_id,source_id,
                max(depth) as depth,
                min(parent_id) as parent_id,
                min(code) as code,
                bool_and(coalesce(is_active,true)) as is_active,
                min(sort_order) as sort_order,
                min(created_at) as created_at,
                bool_or(coalesce(show_in_budget_report,false)) as show_in_budget_report,
                min(budget_sort_order) as budget_sort_order,
                min(flow_type) as flow_type
            from path
            group by target_user_id,target_space_id,source_id
        )
        select * from dedup
        order by target_space_id, depth desc, source_id
    loop
        v_parent_target_id := null;
        if r.parent_id is not null then
            select m.target_id into v_parent_target_id
            from spc001_category_reference_map m
            where m.source_id=r.parent_id
              and m.target_space_id=r.target_space_id;
            if v_parent_target_id is null then
                raise exception 'SPC001_CATEGORY_REPAIR_PARENT_NOT_MAPPED: source=% target_space=%',
                    r.source_id,r.target_space_id;
            end if;
        end if;

        v_created := false;
        select c.id into v_target_id
        from moneytrack.category_catalog c
        where c.space_id=r.target_space_id
          and c.code is not distinct from r.code
        limit 1;

        if v_target_id is null then
            insert into moneytrack.category_catalog(
                user_id,space_id,code,parent_id,is_active,sort_order,created_at,
                show_in_budget_report,budget_sort_order,flow_type,
                created_by_user_id,updated_by_user_id
            ) values (
                r.target_user_id,r.target_space_id,r.code,v_parent_target_id,
                r.is_active,r.sort_order,coalesce(r.created_at,now()),
                r.show_in_budget_report,r.budget_sort_order,r.flow_type,
                r.target_user_id,r.target_user_id
            ) returning id into v_target_id;
            v_created := true;

            insert into spc001_legacy_reference_clones(
                kind,source_id,target_user_id,target_space_id,new_id,source_code
            ) values (
                'category',r.source_id,r.target_user_id,r.target_space_id,v_target_id,r.code
            );
        end if;

        if v_created then
            insert into moneytrack.category_catalog_translations(category_id,language_code,name)
            select v_target_id,tr.language_code,tr.name
            from moneytrack.category_catalog_translations tr
            where tr.category_id=r.source_id
            on conflict (category_id,language_code) do nothing;
        end if;

        insert into spc001_category_reference_map(
            source_id,target_user_id,target_space_id,target_id
        ) values (
            r.source_id,r.target_user_id,r.target_space_id,v_target_id
        ) on conflict (source_id,target_space_id) do update
          set target_id=excluded.target_id,
              target_user_id=excluded.target_user_id;
    end loop;
end;
$repair_category_paths$;

insert into spc001_legacy_reference_repairs(
    kind,row_id,old_target_id,new_target_id,target_user_id,target_space_id
)
select 'receipt_item_category',ri.id,ri.category_id,m.target_id,r.user_id,r.space_id
from moneytrack.receipt_items ri
join moneytrack.receipts r on r.id=ri.receipt_id
join spc001_category_reference_map m
  on m.source_id=ri.category_id
 and m.target_space_id=r.space_id
where ri.category_id is distinct from m.target_id;

insert into spc001_legacy_reference_repairs(
    kind,row_id,old_target_id,new_target_id,target_user_id,target_space_id
)
select 'product_category',p.id,p.category_id,m.target_id,p.user_id,p.space_id
from moneytrack.product_catalog p
join spc001_category_reference_map m
  on m.source_id=p.category_id
 and m.target_space_id=p.space_id
where p.category_id is distinct from m.target_id;

insert into spc001_legacy_reference_repairs(
    kind,row_id,old_target_id,new_target_id,target_user_id,target_space_id
)
select 'budget_category',b.id,b.category_id,m.target_id,b.user_id,b.space_id
from moneytrack.budget_rules b
join spc001_category_reference_map m
  on m.source_id=b.category_id
 and m.target_space_id=b.space_id
where b.category_id is distinct from m.target_id;

update moneytrack.receipt_items ri
set category_id=r.new_target_id
from spc001_legacy_reference_repairs r
where r.kind='receipt_item_category'
  and r.row_id=ri.id
  and ri.category_id=r.old_target_id;

update moneytrack.product_catalog p
set category_id=r.new_target_id
from spc001_legacy_reference_repairs r
where r.kind='product_category'
  and r.row_id=p.id
  and p.category_id=r.old_target_id;

update moneytrack.budget_rules b
set category_id=r.new_target_id
from spc001_legacy_reference_repairs r
where r.kind='budget_category'
  and r.row_id=b.id
  and b.category_id=r.old_target_id;

-- ---------------------------------------------------------------------------
-- Immediate repair postcondition before 010 enables same-Space triggers.
-- ---------------------------------------------------------------------------

do $repair_postcondition$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
    v_clones bigint;
    v_repairs bigint;
begin
    select count(*) into v_count
    from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
    where t.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.receipt_items ri
    join moneytrack.receipts r on r.id=ri.receipt_id
    join moneytrack.category_catalog c on c.id=ri.category_id
    where ri.category_id is not null and r.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id
    where p.category_id is not null and p.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'product_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id
    where b.category_id is not null and b.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'budget_category_cross_space='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_LEGACY_REFERENCE_REPAIR_FAILED: %',array_to_string(v_errors,';');
    end if;

    select count(*) into v_clones from spc001_legacy_reference_clones;
    select count(*) into v_repairs from spc001_legacy_reference_repairs;
    raise notice 'SPC001_LEGACY_REFERENCE_REPAIR=PASS clones=% remaps=%',v_clones,v_repairs;
end;
$repair_postcondition$;
