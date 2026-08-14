-- MoneyTrack — SPC-001D — controlled legacy filter-preset reference repair
-- TRANSACTION BODY ONLY. Runs after the main SPC reconciliation and before the
-- final COMMIT. Legacy UX-022 category arrays may contain global template ids;
-- those ids are remapped, in-place and order-preserving, to the Space-local
-- category with the same stable code. User-local category ids and all account
-- ids remain unchanged.

create temporary table spc001_filter_reference_repairs (
    preset_id bigint not null,
    kind text not null check (kind in ('income_category','expense_category')),
    ordinal bigint not null,
    old_target_id bigint not null,
    new_target_id bigint not null,
    target_space_id bigint not null,
    source_code text not null,
    primary key (preset_id,kind,ordinal),
    check (old_target_id <> new_target_id)
) on commit drop;

insert into spc001_filter_reference_repairs(
    preset_id,kind,ordinal,old_target_id,new_target_id,target_space_id,source_code
)
select
    p.id,
    x.kind,
    x.ord,
    src.id,
    target.id,
    p.space_id,
    src.code
from moneytrack.filter_presets p
cross join lateral (
    select 'income_category'::text as kind,ref.id,ref.ord
    from unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
    union all
    select 'expense_category'::text,ref.id,ref.ord
    from unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
) x
join moneytrack.category_catalog src
  on src.id=x.id
 and src.user_id=0
 and src.space_id is null
join moneytrack.category_catalog target
  on target.space_id=p.space_id
 and target.code is not distinct from src.code
where p.space_id is not null
  and target.id is distinct from src.id;

-- Every template category captured in the baseline must have produced exactly
-- one ledger row. The Space-scoped category-code unique index makes the target
-- unique; a missing target remains fail-closed here.
do $filter_repair_coverage$
declare
    v_expected bigint;
    v_actual bigint;
begin
    select count(*) into v_expected
    from spc001_filter_reference_baseline b
    join moneytrack.category_catalog src on src.id=b.old_target_id
    where b.kind in ('income_category','expense_category')
      and src.user_id=0
      and src.space_id is null;

    select count(*) into v_actual from spc001_filter_reference_repairs;

    if v_actual is distinct from v_expected then
        raise exception 'SPC001_FILTER_PRESET_REPAIR_COVERAGE_FAILED: ledger=% expected=%',
            v_actual,v_expected;
    end if;
end;
$filter_repair_coverage$;

-- Both category arrays are rewritten in ONE row update. The canonical
-- filter-preset same-Space trigger validates the complete NEW row, so separate
-- income/expense updates would expose a transient mixed template/Space state
-- and correctly fail closed before the second update could run.
update moneytrack.filter_presets p
set income_category_ids=(
        select coalesce(array_agg(coalesce(r.new_target_id,x.id) order by x.ord),'{}'::bigint[])
        from unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality x(id,ord)
        left join spc001_filter_reference_repairs r
          on r.preset_id=p.id
         and r.kind='income_category'
         and r.ordinal=x.ord
         and r.old_target_id=x.id
    ),
    expense_category_ids=(
        select coalesce(array_agg(coalesce(r.new_target_id,x.id) order by x.ord),'{}'::bigint[])
        from unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality x(id,ord)
        left join spc001_filter_reference_repairs r
          on r.preset_id=p.id
         and r.kind='expense_category'
         and r.ordinal=x.ord
         and r.old_target_id=x.id
    )
where exists (
    select 1
    from spc001_filter_reference_repairs r
    where r.preset_id=p.id
);

-- Immediate postcondition: every persisted filter reference is now Space-local.
do $filter_repair_postcondition$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
begin
    select count(*) into v_count
    from moneytrack.filter_presets p
    cross join lateral unnest(coalesce(p.account_ids,'{}'::bigint[])) ref(id)
    left join moneytrack.accounts a on a.id=ref.id
    where a.id is null or a.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.filter_presets p
    cross join lateral unnest(
        coalesce(p.income_category_ids,'{}'::bigint[])
        || coalesce(p.expense_category_ids,'{}'::bigint[])
    ) ref(id)
    left join moneytrack.category_catalog c on c.id=ref.id
    where c.id is null or c.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_category_cross_space='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_FILTER_PRESET_REFERENCE_REPAIR_FAILED: %',array_to_string(v_errors,';');
    end if;

    raise notice 'SPC001_FILTER_PRESET_REFERENCE_REPAIR=PASS remaps=%',
        (select count(*) from spc001_filter_reference_repairs);
end;
$filter_repair_postcondition$;
