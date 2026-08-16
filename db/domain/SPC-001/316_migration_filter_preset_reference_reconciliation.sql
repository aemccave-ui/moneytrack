-- MoneyTrack — SPC-001D — filter-preset reference reconciliation
-- TRANSACTION BODY ONLY. Runs after the controlled preset repair and before the
-- final COMMIT. It proves that only ledger-backed template-category ids changed,
-- that array positions/cardinality were preserved, and that every current
-- account/category filter reference belongs to the preset Space.

do $filter_preset_reference_reconcile$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
begin
    -- No non-reference preset field may change after the earlier full migration
    -- reconciliation. Compare against the pre-mutation business digest anyway so
    -- this late repair is independently guarded.
    with current_business as (
        select
            p.id as preset_id,
            md5((to_jsonb(p)-array[
                'space_id','account_ids','income_category_ids','expense_category_ids'
            ]::text[])::text) as business_digest
        from moneytrack.filter_presets p
    )
    select count(*) into v_count
    from spc001_filter_preset_business_baseline b
    full join current_business c using(preset_id)
    where b.preset_id is null
       or c.preset_id is null
       or b.business_digest is distinct from c.business_digest;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_preset_business_changed='||v_count); end if;

    -- Current array elements reconstructed with the same kind+ordinal identity as
    -- the baseline. Missing/extra positions are never allowed.
    with current_refs as (
        select p.id as preset_id,'account'::text as kind,ref.ord as ordinal,ref.id as target_id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.account_ids,'{}'::bigint[])) with ordinality ref(id,ord)
        union all
        select p.id,'income_category',ref.ord,ref.id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
        union all
        select p.id,'expense_category',ref.ord,ref.id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
    )
    select count(*) into v_count
    from spc001_filter_reference_baseline b
    full join current_refs c using(preset_id,kind,ordinal)
    where b.preset_id is null or c.preset_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_reference_position_changed='||v_count); end if;

    -- Any changed value must be described by the exact repair ledger row.
    with current_refs as (
        select p.id as preset_id,'account'::text as kind,ref.ord as ordinal,ref.id as target_id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.account_ids,'{}'::bigint[])) with ordinality ref(id,ord)
        union all
        select p.id,'income_category',ref.ord,ref.id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
        union all
        select p.id,'expense_category',ref.ord,ref.id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
    )
    select count(*) into v_count
    from spc001_filter_reference_baseline b
    join current_refs c using(preset_id,kind,ordinal)
    where c.target_id is distinct from b.old_target_id
      and not exists (
          select 1
          from spc001_filter_reference_repairs r
          where r.preset_id=b.preset_id
            and r.kind=b.kind
            and r.ordinal=b.ordinal
            and r.old_target_id=b.old_target_id
            and r.new_target_id=c.target_id
      );
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_unledgered_reference_change='||v_count); end if;

    -- Every ledger row must correspond to a pre-migration global-template
    -- category and to the current Space-local category with the same stable code.
    with current_refs as (
        select p.id as preset_id,'income_category'::text as kind,ref.ord as ordinal,ref.id as target_id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.income_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
        union all
        select p.id,'expense_category',ref.ord,ref.id
        from moneytrack.filter_presets p
        cross join lateral unnest(coalesce(p.expense_category_ids,'{}'::bigint[])) with ordinality ref(id,ord)
    )
    select count(*) into v_count
    from spc001_filter_reference_repairs r
    left join spc001_filter_reference_baseline b
      on b.preset_id=r.preset_id and b.kind=r.kind and b.ordinal=r.ordinal
    left join current_refs cur
      on cur.preset_id=r.preset_id and cur.kind=r.kind and cur.ordinal=r.ordinal
    left join moneytrack.filter_presets p on p.id=r.preset_id
    left join moneytrack.category_catalog src on src.id=r.old_target_id
    left join moneytrack.category_catalog dst on dst.id=r.new_target_id
    where b.preset_id is null
       or b.old_target_id is distinct from r.old_target_id
       or cur.target_id is distinct from r.new_target_id
       or p.id is null
       or p.space_id is distinct from r.target_space_id
       or src.id is null
       or src.user_id<>0
       or src.space_id is not null
       or dst.id is null
       or dst.space_id is distinct from p.space_id
       or dst.code is distinct from r.source_code
       or src.code is distinct from r.source_code
       or r.old_target_id is not distinct from r.new_target_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_repair_ledger_mismatch='||v_count); end if;

    -- Every persisted reference is now within the financial tenant boundary.
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
        raise exception 'SPC001_FILTER_PRESET_REFERENCE_RECONCILIATION_FAILED: %',array_to_string(v_errors,';');
    end if;

    raise notice 'SPC001_FILTER_PRESET_REFERENCE_LEDGER=PASS remaps=%',
        (select count(*) from spc001_filter_reference_repairs);
    raise notice 'SPC001_FILTER_PRESET_REFERENCES=PASS';
end;
$filter_preset_reference_reconcile$;
