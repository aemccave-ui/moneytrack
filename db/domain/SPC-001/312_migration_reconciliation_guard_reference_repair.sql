-- MoneyTrack — SPC-001D — atomic reconciliation with controlled reference repair
-- TRANSACTION BODY ONLY. Any mismatch raises and rolls the complete migration
-- transaction back. Only ledger-backed FK remaps and ledger-backed account/
-- category shadow clones are allowed to differ from the pre-mutation baseline.

create temporary table spc001_migration_current (
    metric text primary key,
    row_count bigint not null,
    amount_1 numeric,
    amount_2 numeric,
    row_digest text not null
) on commit drop;

-- Shadow clones are deliberately excluded from the legacy row digest. Their
-- existence and exact count are separately reconciled against the clone ledger.
insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'accounts',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(a)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by a.id),''))
from moneytrack.accounts a
where not exists (
    select 1 from spc001_legacy_reference_clones c
    where c.kind='account' and c.new_id=a.id
);

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'transactions',count(*),coalesce(sum(t.amount_original),0),coalesce(sum(t.amount_base),0),
       md5(coalesce(string_agg(md5((to_jsonb(t)-array['space_id','created_by_user_id','updated_by_user_id','capture_event_id','account_id']::text[])::text),'' order by t.id),''))
from moneytrack.transactions t;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'transfers',count(*),coalesce(sum(t.from_amount),0),coalesce(sum(t.to_amount),0),
       md5(coalesce(string_agg(md5((to_jsonb(t)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by t.id),''))
from moneytrack.transfers t;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'receipts',count(*),coalesce(sum(r.total_amount),0),null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(r)-array['space_id','captured_by_user_id']::text[])::text),'' order by r.id),''))
from moneytrack.receipts r;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'receipt_items',count(*),coalesce(sum(ri.amount),0),coalesce(sum(ri.quantity),0),
       md5(coalesce(string_agg(md5((to_jsonb(ri)-'category_id')::text),'' order by ri.id),''))
from moneytrack.receipt_items ri;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'category_catalog',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(c)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by c.id),''))
from moneytrack.category_catalog c
where not exists (
    select 1 from spc001_legacy_reference_clones x
    where x.kind='category' and x.new_id=c.id
);

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'product_catalog',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(p)-array['space_id','created_by_user_id','updated_by_user_id','category_id']::text[])::text),'' order by p.id),''))
from moneytrack.product_catalog p;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'budget_rules',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(b)-array['space_id','created_by_user_id','updated_by_user_id','category_id']::text[])::text),'' order by b.id),''))
from moneytrack.budget_rules b;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'filter_presets',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(p)-array['space_id']::text[])::text),'' order by p.id),''))
from moneytrack.filter_presets p;

do $reconcile$
declare
    v_errors text[]:='{}'::text[];
    v_count bigint;
    v_expected bigint;
    v_actual bigint;
begin
    -- Legacy rows, monetary totals and every non-allowed business field remain
    -- byte-for-byte equivalent to the baseline.
    select count(*) into v_count
      from spc001_migration_baseline b
      full join spc001_migration_current c using(metric)
     where b.metric is null or c.metric is null
        or b.row_count is distinct from c.row_count
        or b.amount_1 is distinct from c.amount_1
        or b.amount_2 is distinct from c.amount_2
        or b.row_digest is distinct from c.row_digest;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_business_data_changed='||v_count); end if;

    -- New account/category rows are allowed only when listed in clone ledger.
    select row_count into v_expected from spc001_migration_baseline where metric='accounts';
    select count(*) into v_actual from moneytrack.accounts;
    v_expected := v_expected + (select count(*) from spc001_legacy_reference_clones where kind='account');
    if v_actual is distinct from v_expected then
        v_errors:=array_append(v_errors,'account_clone_count_mismatch='||v_actual||'/'||v_expected);
    end if;

    select row_count into v_expected from spc001_migration_baseline where metric='category_catalog';
    select count(*) into v_actual from moneytrack.category_catalog;
    v_expected := v_expected + (select count(*) from spc001_legacy_reference_clones where kind='category');
    if v_actual is distinct from v_expected then
        v_errors:=array_append(v_errors,'category_clone_count_mismatch='||v_actual||'/'||v_expected);
    end if;

    select count(*) into v_count
    from spc001_legacy_reference_clones l
    left join moneytrack.accounts a on l.kind='account' and a.id=l.new_id
    left join moneytrack.category_catalog c on l.kind='category' and c.id=l.new_id
    where (l.kind='account' and (
              a.id is null
           or a.user_id is distinct from l.target_user_id
           or a.space_id is distinct from l.target_space_id
           or a.code is distinct from l.source_code
          ))
       or (l.kind='category' and (
              c.id is null
           or c.user_id is distinct from l.target_user_id
           or c.space_id is distinct from l.target_space_id
           or c.code is distinct from l.source_code
          ));
    if v_count<>0 then v_errors:=array_append(v_errors,'clone_ledger_mismatch='||v_count); end if;

    -- Reconstruct current values for every FK snapshotted before migration.
    with current_refs as (
        select 'transaction_account'::text as kind,t.id as row_id,t.account_id as target_id
        from moneytrack.transactions t
        union all
        select 'receipt_item_category',ri.id,ri.category_id
        from moneytrack.receipt_items ri where ri.category_id is not null
        union all
        select 'product_category',p.id,p.category_id
        from moneytrack.product_catalog p where p.category_id is not null
        union all
        select 'budget_category',b.id,b.category_id
        from moneytrack.budget_rules b where b.category_id is not null
    )
    select count(*) into v_count
    from spc001_reference_baseline b
    join current_refs c using(kind,row_id)
    where c.target_id is distinct from b.old_target_id
      and not exists (
          select 1
          from spc001_legacy_reference_repairs r
          where r.kind=b.kind
            and r.row_id=b.row_id
            and r.old_target_id=b.old_target_id
            and r.new_target_id=c.target_id
      );
    if v_count<>0 then v_errors:=array_append(v_errors,'unledgered_reference_change='||v_count); end if;

    with current_refs as (
        select 'transaction_account'::text as kind,t.id as row_id,t.account_id as target_id from moneytrack.transactions t
        union all
        select 'receipt_item_category',ri.id,ri.category_id from moneytrack.receipt_items ri where ri.category_id is not null
        union all
        select 'product_category',p.id,p.category_id from moneytrack.product_catalog p where p.category_id is not null
        union all
        select 'budget_category',b.id,b.category_id from moneytrack.budget_rules b where b.category_id is not null
    )
    select count(*) into v_count
    from spc001_legacy_reference_repairs r
    left join spc001_reference_baseline b on b.kind=r.kind and b.row_id=r.row_id
    left join current_refs c on c.kind=r.kind and c.row_id=r.row_id
    where b.row_id is null
       or b.old_target_id is distinct from r.old_target_id
       or c.target_id is distinct from r.new_target_id
       or r.old_target_id is not distinct from r.new_target_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_ledger_mismatch='||v_count); end if;

    -- Every non-template user has exactly one active Personal Space and is its
    -- active owner member.
    select count(*) into v_count
      from moneytrack.app_users u
     where u.id<>0
       and 1<>(
           select count(*)
             from moneytrack.workspaces w
             join moneytrack.workspace_members wm
               on wm.workspace_id=w.id
              and wm.user_id=u.id
              and coalesce(wm.is_active,true)=true
            where w.owner_user_id=u.id
              and w.workspace_type='personal'
              and coalesce(w.is_active,true)=true
       );
    if v_count<>0 then v_errors:=array_append(v_errors,'personal_space_cardinality='||v_count); end if;

    select count(*) into v_count
      from moneytrack.workspaces w
      join moneytrack.workspace_members wm on wm.workspace_id=w.id
     where w.workspace_type='personal'
       and coalesce(w.is_active,true)=true
       and coalesce(wm.is_active,true)=true
       and wm.user_id is distinct from w.owner_user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'personal_space_foreign_members='||v_count); end if;

    -- Every non-template legacy/synthetic finance row belongs to its user actor's
    -- initial Personal Space. This includes repair clones, whose durable user_id
    -- is deliberately rewritten to the target owner to sever foreign linkage.
    select count(*) into v_count from moneytrack.accounts x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'accounts_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transfers x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'transfers_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.receipts x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'receipts_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'categories_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'products_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.budget_rules x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'budgets_wrong_personal_space='||v_count); end if;
    select count(*) into v_count from moneytrack.filter_presets x join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_presets_wrong_personal_space='||v_count); end if;

    -- Template/platform finance remains global and never receives a Space.
    select count(*) into v_count from moneytrack.accounts where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_accounts_space_leak='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_categories_space_leak='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_products_space_leak='||v_count); end if;

    -- Complete same-Space relational consistency after repair.
    select count(*) into v_count from moneytrack.accounts a join moneytrack.accounts p on p.id=a.parent_id
     where a.parent_id is not null and a.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'account_parent_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog c join moneytrack.category_catalog p on p.id=c.parent_id
     where c.parent_id is not null and c.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'category_parent_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
     where t.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_account_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions t join moneytrack.category_catalog c on c.id=t.category_id
     where t.category_id is not null and t.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_category_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transfers t join moneytrack.accounts a1 on a1.id=t.from_account_id join moneytrack.accounts a2 on a2.id=t.to_account_id
     where t.space_id is distinct from a1.space_id or t.space_id is distinct from a2.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfer_account_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.receipts r join moneytrack.transactions t on t.id=r.transaction_id
     where r.space_id is distinct from t.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_transaction_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id
     where ri.category_id is not null and c.space_id is distinct from r.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_category_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.product_catalog p on p.id=ri.product_id
     where ri.product_id is not null and p.space_id is distinct from r.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_product_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id
     where p.category_id is not null and p.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'product_category_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id
     where b.category_id is not null and b.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'budget_category_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.space_default_accounts d join moneytrack.accounts a on a.id=d.account_id
     where d.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_account_cross_space='||v_count); end if;
    select count(*) into v_count from moneytrack.space_financial_settings s join moneytrack.accounts a on a.id in (s.default_expense_account_id,s.default_income_account_id)
     where a.space_id is distinct from s.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'financial_setting_account_cross_space='||v_count); end if;

    -- Existing finance is fully represented by immutable capture provenance.
    select count(*) into v_count from moneytrack.transactions t where t.user_id<>0 and t.capture_event_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_without_capture_event='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions t left join moneytrack.capture_events e on e.id=t.capture_event_id and e.legacy_transaction_id=t.id
     where t.user_id<>0 and e.id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_transaction_capture_mapping='||v_count); end if;
    select count(*) into v_count from moneytrack.receipts r left join moneytrack.capture_receipts cr on cr.legacy_receipt_id=r.id
     where r.user_id<>0 and cr.id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_receipt_capture_mapping='||v_count); end if;
    select count(*) into v_count from moneytrack.receipt_items ri left join moneytrack.capture_receipt_items cri on cri.legacy_receipt_item_id=ri.id
     where cri.id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_receipt_item_capture_mapping='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_ATOMIC_RECONCILIATION_FAILED: %',array_to_string(v_errors,';');
    end if;

    raise notice 'SPC001_REFERENCE_REPAIR_LEDGER=PASS clones=% remaps=%',
        (select count(*) from spc001_legacy_reference_clones),
        (select count(*) from spc001_legacy_reference_repairs);
    raise notice 'SPC001_LEGACY_ROW_DIGESTS=PASS';
    raise notice 'SPC001_LEGACY_MONETARY_TOTALS=PASS';
    raise notice 'SPC001_PERSONAL_SPACE_MIGRATION=PASS';
    raise notice 'SPC001_SAME_SPACE_REFERENCES=PASS';
    raise notice 'SPC001_CAPTURE_PROVENANCE_MIGRATION=PASS';
end;
$reconcile$;
