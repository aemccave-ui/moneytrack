-- MoneyTrack — SPC-001D — atomic migration reconciliation guard
--
-- TRANSACTION BODY ONLY. Consumed by scripts/spc001-build-db-migration.py after
-- all SPC-001 mutation units and before the enclosing COMMIT. Any mismatch raises
-- and rolls the complete migration transaction back.

create temporary table spc001_migration_current (
    metric text primary key,
    row_count bigint not null,
    amount_1 numeric,
    amount_2 numeric,
    row_digest text not null
) on commit drop;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'accounts',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(a)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by a.id),''))
from moneytrack.accounts a;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'transactions',count(*),coalesce(sum(t.amount_original),0),coalesce(sum(t.amount_base),0),
       md5(coalesce(string_agg(md5((to_jsonb(t)-array['space_id','created_by_user_id','updated_by_user_id','capture_event_id']::text[])::text),'' order by t.id),''))
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
       md5(coalesce(string_agg(md5(to_jsonb(ri)::text),'' order by ri.id),''))
from moneytrack.receipt_items ri;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'category_catalog',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(c)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by c.id),''))
from moneytrack.category_catalog c;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'product_catalog',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(p)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by p.id),''))
from moneytrack.product_catalog p;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'budget_rules',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(b)-array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),'' order by b.id),''))
from moneytrack.budget_rules b;

insert into spc001_migration_current(metric,row_count,amount_1,amount_2,row_digest)
select 'filter_presets',count(*),null::numeric,null::numeric,
       md5(coalesce(string_agg(md5((to_jsonb(p)-array['space_id']::text[])::text),'' order by p.id),''))
from moneytrack.filter_presets p;

do $reconcile$
declare
    v_errors text[]:='{}'::text[];
    v_count bigint;
begin
    select count(*) into v_count
      from spc001_migration_baseline b
      full join spc001_migration_current c using(metric)
     where b.metric is null or c.metric is null
        or b.row_count is distinct from c.row_count
        or b.amount_1 is distinct from c.amount_1
        or b.amount_2 is distinct from c.amount_2
        or b.row_digest is distinct from c.row_digest;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_business_data_changed='||v_count); end if;

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

    -- Legacy rows must map to their owner's unique Personal Space. The legacy
    -- user_id stays as compatibility/provenance only; it is no longer tenancy.
    select count(*) into v_count
      from moneytrack.accounts x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'accounts_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transfers x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'transfers_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipts x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'receipts_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.category_catalog x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'categories_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.product_catalog x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'products_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.budget_rules x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'budgets_wrong_personal_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.filter_presets x
      join moneytrack.workspaces w on w.id=x.space_id
     where x.user_id<>0 and (w.owner_user_id is distinct from x.user_id or w.workspace_type<>'personal');
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_presets_wrong_personal_space='||v_count); end if;

    -- Template/platform finance remains global and never receives a Space.
    select count(*) into v_count from moneytrack.accounts where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_accounts_space_leak='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_categories_space_leak='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_products_space_leak='||v_count); end if;

    -- Same-Space relational consistency.
    select count(*) into v_count
      from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
     where t.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_account_cross_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions t join moneytrack.category_catalog c on c.id=t.category_id
     where t.category_id is not null and t.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_category_cross_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transfers t
      join moneytrack.accounts a1 on a1.id=t.from_account_id
      join moneytrack.accounts a2 on a2.id=t.to_account_id
     where t.space_id is distinct from a1.space_id or t.space_id is distinct from a2.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfer_account_cross_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipts r join moneytrack.transactions t on t.id=r.transaction_id
     where r.space_id is distinct from t.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_transaction_cross_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.category_catalog c on c.id=ri.category_id
     where ri.category_id is not null and c.space_id is distinct from r.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_category_cross_space='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.product_catalog p on p.id=ri.product_id
     where ri.product_id is not null and p.space_id is distinct from r.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_product_cross_space='||v_count); end if;

    -- Existing finance is fully represented by immutable capture provenance.
    select count(*) into v_count
      from moneytrack.transactions t
     where t.user_id<>0 and t.capture_event_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_without_capture_event='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions t
      left join moneytrack.capture_events e
        on e.id=t.capture_event_id and e.legacy_transaction_id=t.id
     where t.user_id<>0 and e.id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_transaction_capture_mapping='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipts r
      left join moneytrack.capture_receipts cr on cr.legacy_receipt_id=r.id
     where r.user_id<>0 and cr.id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_receipt_capture_mapping='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipt_items ri
      left join moneytrack.capture_receipt_items cri on cri.legacy_receipt_item_id=ri.id
     where cri.id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'legacy_receipt_item_capture_mapping='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_ATOMIC_RECONCILIATION_FAILED: %',array_to_string(v_errors,';');
    end if;

    raise notice 'SPC001_LEGACY_ROW_DIGESTS=PASS';
    raise notice 'SPC001_LEGACY_MONETARY_TOTALS=PASS';
    raise notice 'SPC001_PERSONAL_SPACE_MIGRATION=PASS';
    raise notice 'SPC001_SAME_SPACE_REFERENCES=PASS';
    raise notice 'SPC001_CAPTURE_PROVENANCE_MIGRATION=PASS';
end;
$reconcile$;
