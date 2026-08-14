-- MoneyTrack — SPC-001D — atomic migration baseline with reference-repair allowance
--
-- TRANSACTION BODY ONLY. Snapshots legacy business state before SPC mutation.
-- The only business-field changes allowed later are FK remaps explicitly recorded
-- in spc001_legacy_reference_repairs. Account/category shadow clones must be
-- explicitly recorded in spc001_legacy_reference_clones.

create temporary table spc001_migration_baseline (
    metric text primary key,
    row_count bigint not null,
    amount_1 numeric,
    amount_2 numeric,
    row_digest text not null
) on commit drop;

-- Snapshot every FK whose value may be changed by the controlled legacy repair.
-- Same-user rows are included too, so an accidental remap outside the repair
-- ledger is detectable before COMMIT.
create temporary table spc001_reference_baseline (
    kind text not null,
    row_id bigint not null,
    old_target_id bigint not null,
    primary key (kind, row_id)
) on commit drop;

insert into spc001_reference_baseline(kind,row_id,old_target_id)
select 'transaction_account', t.id, t.account_id
from moneytrack.transactions t;

insert into spc001_reference_baseline(kind,row_id,old_target_id)
select 'receipt_item_category', ri.id, ri.category_id
from moneytrack.receipt_items ri
where ri.category_id is not null;

insert into spc001_reference_baseline(kind,row_id,old_target_id)
select 'product_category', p.id, p.category_id
from moneytrack.product_catalog p
where p.category_id is not null;

insert into spc001_reference_baseline(kind,row_id,old_target_id)
select 'budget_category', b.id, b.category_id
from moneytrack.budget_rules b
where b.category_id is not null;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'accounts', count(*), null::numeric, null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(a) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by a.id
    ),''))
from moneytrack.accounts a;

-- account_id is excluded only because exact old/new values are separately
-- protected by spc001_reference_baseline + the repair ledger.
insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'transactions', count(*), coalesce(sum(t.amount_original),0), coalesce(sum(t.amount_base),0),
    md5(coalesce(string_agg(
        md5((to_jsonb(t) - array['space_id','created_by_user_id','updated_by_user_id','capture_event_id','account_id']::text[])::text),
        '' order by t.id
    ),''))
from moneytrack.transactions t;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'transfers', count(*), coalesce(sum(t.from_amount),0), coalesce(sum(t.to_amount),0),
    md5(coalesce(string_agg(
        md5((to_jsonb(t) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by t.id
    ),''))
from moneytrack.transfers t;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'receipts', count(*), coalesce(sum(r.total_amount),0), null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(r) - array['space_id','captured_by_user_id']::text[])::text),
        '' order by r.id
    ),''))
from moneytrack.receipts r;

-- category_id is separately protected by the reference baseline + repair ledger.
insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'receipt_items', count(*), coalesce(sum(ri.amount),0), coalesce(sum(ri.quantity),0),
    md5(coalesce(string_agg(md5((to_jsonb(ri)-'category_id')::text),'' order by ri.id),''))
from moneytrack.receipt_items ri;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'category_catalog', count(*), null::numeric, null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(c) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by c.id
    ),''))
from moneytrack.category_catalog c;

-- category_id is separately protected by the reference baseline + repair ledger.
insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'product_catalog', count(*), null::numeric, null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(p) - array['space_id','created_by_user_id','updated_by_user_id','category_id']::text[])::text),
        '' order by p.id
    ),''))
from moneytrack.product_catalog p;

-- category_id is separately protected by the reference baseline + repair ledger.
insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'budget_rules', count(*), null::numeric, null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(b) - array['space_id','created_by_user_id','updated_by_user_id','category_id']::text[])::text),
        '' order by b.id
    ),''))
from moneytrack.budget_rules b;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'filter_presets', count(*), null::numeric, null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(p) - array['space_id']::text[])::text),
        '' order by p.id
    ),''))
from moneytrack.filter_presets p;

do $baseline_ready$
declare
    v_reference_rows bigint;
begin
    if (select count(*) from spc001_migration_baseline) <> 9 then
        raise exception 'SPC001_MIGRATION_BASELINE_INCOMPLETE';
    end if;
    select count(*) into v_reference_rows from spc001_reference_baseline;
    raise notice 'SPC001_MIGRATION_BASELINE=PASS metrics=9 reference_rows=%', v_reference_rows;
end;
$baseline_ready$;
