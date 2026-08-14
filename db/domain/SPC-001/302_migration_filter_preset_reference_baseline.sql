-- MoneyTrack — SPC-001D — filter-preset reference baseline
-- TRANSACTION BODY ONLY. Captures every legacy UX-022 array element and the
-- non-reference preset payload before SPC mutation. Array order is part of the
-- contract and is therefore snapshotted with ordinality.

create temporary table spc001_filter_reference_baseline (
    preset_id bigint not null,
    kind text not null check (kind in ('account','income_category','expense_category')),
    ordinal bigint not null,
    old_target_id bigint not null,
    primary key (preset_id,kind,ordinal)
) on commit drop;

insert into spc001_filter_reference_baseline(preset_id,kind,ordinal,old_target_id)
select p.id,'account',ref.ord,ref.id
from moneytrack.filter_presets p
cross join lateral unnest(coalesce(p.account_ids,'{}'::bigint[])) with ordinality ref(id,ord);

insert into spc001_filter_reference_baseline(preset_id,kind,ordinal,old_target_id)
select p.id,'income_category',ref.ord,ref.id
from moneytrack.filter_presets p
cross join lateral unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality ref(id,ord);

insert into spc001_filter_reference_baseline(preset_id,kind,ordinal,old_target_id)
select p.id,'expense_category',ref.ord,ref.id
from moneytrack.filter_presets p
cross join lateral unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality ref(id,ord);

create temporary table spc001_filter_preset_business_baseline (
    preset_id bigint primary key,
    business_digest text not null
) on commit drop;

insert into spc001_filter_preset_business_baseline(preset_id,business_digest)
select
    p.id,
    md5((to_jsonb(p)-array[
        'space_id','account_ids','income_category_ids','expense_category_ids'
    ]::text[])::text)
from moneytrack.filter_presets p;

do $filter_preset_baseline_ready$
declare
    v_refs bigint;
begin
    select count(*) into v_refs from spc001_filter_reference_baseline;
    raise notice 'SPC001_FILTER_PRESET_BASELINE=PASS refs=% presets=%',
        v_refs,(select count(*) from spc001_filter_preset_business_baseline);
end;
$filter_preset_baseline_ready$;
