-- MoneyTrack — SPC-001D3 — legacy filter-preset reference diagnostic
-- READ ONLY. Proves whether UX-022 account/category arrays can be migrated
-- deterministically from user/global-template references into Space-local refs.
-- No row, sequence, workflow, or runtime state is mutated.

\set ON_ERROR_STOP on
begin transaction read only;
\pset tuples_only on
\pset format unaligned

\echo SPC001_FILTER_PRESET_REFERENCE_DIAGNOSTIC=BEGIN

do $diagnostic$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
begin
    -- Legacy UX-022 account ids were user-local only. Missing/cross-user ids are
    -- not silently remapped because that would broaden the old contract.
    select count(*) into v_count
    from moneytrack.filter_presets p
    cross join lateral unnest(coalesce(p.account_ids,'{}'::bigint[])) with ordinality ref(id,ord)
    left join moneytrack.accounts a on a.id=ref.id
    where a.id is null or a.user_id is distinct from p.user_id;
    if v_count<>0 then
        v_errors:=array_append(v_errors,'filter_account_reference_invalid='||v_count);
    end if;

    -- Legacy UX-022 category ids could be either user-local or global template
    -- (user_id=0). Any other owner is outside the accepted legacy contract.
    select count(*) into v_count
    from moneytrack.filter_presets p
    cross join lateral unnest(
        coalesce(p.income_category_ids,'{}'::bigint[])
        || coalesce(p.expense_category_ids,'{}'::bigint[])
    ) with ordinality ref(id,ord)
    left join moneytrack.category_catalog c on c.id=ref.id
    where c.id is null or c.user_id not in (0,p.user_id);
    if v_count<>0 then
        v_errors:=array_append(v_errors,'filter_category_reference_invalid='||v_count);
    end if;

    -- Template refs are repairable only through the same stable-code identity
    -- used by catalog_ensure_space_categories_v1(): exactly one user-local
    -- category with the template code must already exist in the legacy catalog.
    select count(*) into v_count
    from (
        select distinct p.user_id,c.id as template_category_id,c.code
        from moneytrack.filter_presets p
        cross join lateral unnest(
            coalesce(p.income_category_ids,'{}'::bigint[])
            || coalesce(p.expense_category_ids,'{}'::bigint[])
        ) ref(id)
        join moneytrack.category_catalog c on c.id=ref.id
        where c.user_id=0
    ) q
    where nullif(btrim(q.code),'') is null;
    if v_count<>0 then
        v_errors:=array_append(v_errors,'filter_template_category_code_missing='||v_count);
    end if;

    select count(*) into v_count
    from (
        select distinct p.user_id,c.id as template_category_id,c.code
        from moneytrack.filter_presets p
        cross join lateral unnest(
            coalesce(p.income_category_ids,'{}'::bigint[])
            || coalesce(p.expense_category_ids,'{}'::bigint[])
        ) ref(id)
        join moneytrack.category_catalog c on c.id=ref.id
        where c.user_id=0
    ) q
    where (
        select count(*)
        from moneytrack.category_catalog target
        where target.user_id=q.user_id
          and target.code is not distinct from q.code
    )<>1;
    if v_count<>0 then
        v_errors:=array_append(v_errors,'filter_template_category_target_not_unique='||v_count);
    end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_FILTER_PRESET_REFERENCE_DIAGNOSTIC_FAILED: %',array_to_string(v_errors,';');
    end if;
end;
$diagnostic$;

select 'FILTER_ACCOUNT_REFS|total='||count(*)
from moneytrack.filter_presets p
cross join lateral unnest(coalesce(p.account_ids,'{}'::bigint[])) ref(id);

select 'FILTER_CATEGORY_REFS|total='||count(*)
    ||'|template='||count(*) filter (where c.user_id=0)
    ||'|user_local='||count(*) filter (where c.user_id=p.user_id)
from moneytrack.filter_presets p
cross join lateral unnest(
    coalesce(p.income_category_ids,'{}'::bigint[])
    || coalesce(p.expense_category_ids,'{}'::bigint[])
) ref(id)
join moneytrack.category_catalog c on c.id=ref.id;

select 'FILTER_TEMPLATE_MAP|refs='||count(*)
    ||'|candidate_zero='||count(*) filter (where q.candidate_count=0)
    ||'|candidate_one='||count(*) filter (where q.candidate_count=1)
    ||'|candidate_many='||count(*) filter (where q.candidate_count>1)
from (
    select p.id as preset_id,p.user_id,c.id as source_id,c.code,
           (select count(*) from moneytrack.category_catalog target
             where target.user_id=p.user_id
               and target.code is not distinct from c.code) as candidate_count
    from moneytrack.filter_presets p
    cross join lateral unnest(
        coalesce(p.income_category_ids,'{}'::bigint[])
        || coalesce(p.expense_category_ids,'{}'::bigint[])
    ) ref(id)
    join moneytrack.category_catalog c on c.id=ref.id
    where c.user_id=0
) q;

select 'FILTER_TEMPLATE_REF|preset='||p.id
    ||'|user='||p.user_id
    ||'|kind='||x.kind
    ||'|ord='||x.ord
    ||'|source_id='||c.id
    ||'|code='||coalesce(c.code,'<NULL>')
    ||'|candidate_count='||cand.candidate_count
    ||'|candidate_id='||coalesce(cand.candidate_id::text,'<NULL>')
from moneytrack.filter_presets p
cross join lateral (
    select 'income'::text as kind,ref.id,ref.ord
    from unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
    union all
    select 'expense'::text,ref.id,ref.ord
    from unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
) x
join moneytrack.category_catalog c on c.id=x.id and c.user_id=0
cross join lateral (
    select count(*)::bigint as candidate_count,min(target.id) as candidate_id
    from moneytrack.category_catalog target
    where target.user_id=p.user_id
      and target.code is not distinct from c.code
) cand
order by p.id,x.kind,x.ord;

select 'SPC001_FILTER_PRESET_REFERENCE_DIAGNOSTIC=PASS';
\echo SPC001_FILTER_PRESET_REFERENCE_DIAGNOSTIC=END
rollback;
