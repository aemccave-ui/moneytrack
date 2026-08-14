-- MoneyTrack — SPC-001D — atomic migration baseline fragment
--
-- TRANSACTION BODY ONLY. This file is consumed by
-- scripts/spc001-build-db-migration.py before any SPC schema/data mutation.
-- It snapshots legacy business rows while deliberately ignoring only columns
-- introduced by SPC-001. The reconciliation fragment must prove these rows and
-- monetary totals are unchanged before the enclosing transaction may COMMIT.

create temporary table spc001_migration_baseline (
    metric text primary key,
    row_count bigint not null,
    amount_1 numeric,
    amount_2 numeric,
    row_digest text not null
) on commit drop;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'accounts',
    count(*),
    null::numeric,
    null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(a) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by a.id
    ),''))
from moneytrack.accounts a;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'transactions',
    count(*),
    coalesce(sum(t.amount_original),0),
    coalesce(sum(t.amount_base),0),
    md5(coalesce(string_agg(
        md5((to_jsonb(t) - array['space_id','created_by_user_id','updated_by_user_id','capture_event_id']::text[])::text),
        '' order by t.id
    ),''))
from moneytrack.transactions t;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'transfers',
    count(*),
    coalesce(sum(t.from_amount),0),
    coalesce(sum(t.to_amount),0),
    md5(coalesce(string_agg(
        md5((to_jsonb(t) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by t.id
    ),''))
from moneytrack.transfers t;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'receipts',
    count(*),
    coalesce(sum(r.total_amount),0),
    null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(r) - array['space_id','captured_by_user_id']::text[])::text),
        '' order by r.id
    ),''))
from moneytrack.receipts r;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'receipt_items',
    count(*),
    coalesce(sum(ri.amount),0),
    coalesce(sum(ri.quantity),0),
    md5(coalesce(string_agg(md5(to_jsonb(ri)::text),'' order by ri.id),''))
from moneytrack.receipt_items ri;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'category_catalog',
    count(*),
    null::numeric,
    null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(c) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by c.id
    ),''))
from moneytrack.category_catalog c;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'product_catalog',
    count(*),
    null::numeric,
    null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(p) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by p.id
    ),''))
from moneytrack.product_catalog p;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'budget_rules',
    count(*),
    null::numeric,
    null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(b) - array['space_id','created_by_user_id','updated_by_user_id']::text[])::text),
        '' order by b.id
    ),''))
from moneytrack.budget_rules b;

insert into spc001_migration_baseline(metric,row_count,amount_1,amount_2,row_digest)
select
    'filter_presets',
    count(*),
    null::numeric,
    null::numeric,
    md5(coalesce(string_agg(
        md5((to_jsonb(p) - array['space_id']::text[])::text),
        '' order by p.id
    ),''))
from moneytrack.filter_presets p;

do $baseline_ready$
begin
    if (select count(*) from spc001_migration_baseline) <> 9 then
        raise exception 'SPC001_MIGRATION_BASELINE_INCOMPLETE';
    end if;
    raise notice 'SPC001_MIGRATION_BASELINE=PASS metrics=9';
end;
$baseline_ready$;
