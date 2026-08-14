-- MoneyTrack — SPC-001D — legacy reference provenance diagnostic
-- READ ONLY. Explains unresolved cross-user references without changing data.
-- It distinguishes current owner-local candidates from canonical template-backed
-- values that the SPC bootstrap can recreate inside the future Personal Space.

\set ON_ERROR_STOP on
begin transaction read only;
\pset tuples_only on
\pset format unaligned

select 'SPC001_REFERENCE_PROVENANCE_DIAGNOSTIC=BEGIN';

-- ---------------------------------------------------------------------------
-- 1. Cross-user transaction/account provenance and receipt ownership.
-- ---------------------------------------------------------------------------
select format(
    'TX_PROVENANCE|transaction_id=%s|row_user=%s|transaction_type=%s|amount=%s|currency=%s|transaction_date=%s|source_type=%s|source_id=%s|target_account_id=%s|target_account_user=%s|target_account_code=%s|target_account_name=%s|target_account_currency=%s|linked_receipt_count=%s|linked_receipt_ids=%s|linked_receipt_users=%s|receipt_owner_match=%s',
    t.id,
    t.user_id,
    coalesce(t.transaction_type,''),
    coalesce(t.amount_original::text,''),
    coalesce(t.currency_original,''),
    coalesce(t.transaction_date::text,''),
    coalesce(t.source_type,''),
    coalesce(t.source_id::text,''),
    a.id,
    a.user_id,
    coalesce(a.code,''),
    replace(coalesce(a.name,''),'|','/'),
    coalesce(a.currency_code,''),
    coalesce(r.receipt_count,0),
    coalesce(r.receipt_ids,''),
    coalesce(r.receipt_users,''),
    case
      when coalesce(r.receipt_count,0)=0 then 'NO_RECEIPT'
      when coalesce(r.foreign_owner_count,0)=0 then 'YES'
      else 'NO'
    end
)
from moneytrack.transactions t
join moneytrack.accounts a on a.id=t.account_id
left join lateral (
    select
        count(*)::bigint as receipt_count,
        string_agg(x.id::text,',' order by x.id) as receipt_ids,
        string_agg(x.user_id::text,',' order by x.id) as receipt_users,
        count(*) filter(where x.user_id is distinct from t.user_id)::bigint as foreign_owner_count
    from moneytrack.receipts x
    where x.transaction_id=t.id
) r on true
where a.user_id is distinct from t.user_id
order by t.id;

-- ---------------------------------------------------------------------------
-- 2. Foreign account targets: is the exact code canonical-template backed?
-- If template_exact_count=1, SPC bootstrap can recreate that code in every
-- Personal Space. Otherwise cloning a foreign user's account would be a new
-- migration policy and is deliberately NOT inferred here.
-- ---------------------------------------------------------------------------
select format(
    'ACCOUNT_TARGET_PROVENANCE|target_id=%s|target_user=%s|code=%s|name=%s|account_type=%s|currency=%s|parent_id=%s|parent_code=%s|template_exact_count=%s|template_ids=%s|global_same_code_count=%s|referencing_row_users=%s',
    a.id,
    a.user_id,
    coalesce(a.code,''),
    replace(coalesce(a.name,''),'|','/'),
    coalesce(a.account_type,''),
    coalesce(a.currency_code,''),
    coalesce(a.parent_id::text,''),
    coalesce(parent.code,''),
    coalesce(tpl.template_count,0),
    coalesce(tpl.template_ids,''),
    coalesce(glob.global_count,0),
    coalesce(refs.row_users,'')
)
from moneytrack.accounts a
left join moneytrack.accounts parent on parent.id=a.parent_id
join lateral (
    select string_agg(distinct t.user_id::text,',' order by t.user_id::text) as row_users
    from moneytrack.transactions t
    where t.account_id=a.id and t.user_id is distinct from a.user_id
) refs on refs.row_users is not null
left join lateral (
    select count(*)::bigint as template_count,
           string_agg(x.id::text,',' order by x.id) as template_ids
    from moneytrack.accounts x
    where x.user_id=0 and x.code is not distinct from a.code
) tpl on true
left join lateral (
    select count(*)::bigint as global_count
    from moneytrack.accounts x
    where x.code is not distinct from a.code
) glob on true
order by a.id;

-- ---------------------------------------------------------------------------
-- 3. Foreign category targets used by receipt items/products/budgets.
-- Include parent topology because template bootstrap recreates parent/child
-- categories by code, not by legacy id.
-- ---------------------------------------------------------------------------
with referenced as (
    select c.id as category_id, r.user_id as row_user, 'receipt_item'::text as kind
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.category_catalog c on c.id=ri.category_id
     where ri.category_id is not null and c.user_id is distinct from r.user_id
    union all
    select c.id, p.user_id, 'product'
      from moneytrack.product_catalog p
      join moneytrack.category_catalog c on c.id=p.category_id
     where p.category_id is not null and c.user_id is distinct from p.user_id
    union all
    select c.id, b.user_id, 'budget'
      from moneytrack.budget_rules b
      join moneytrack.category_catalog c on c.id=b.category_id
     where b.category_id is not null and c.user_id is distinct from b.user_id
), grouped as (
    select category_id,
           string_agg(distinct row_user::text,',' order by row_user::text) as row_users,
           string_agg(distinct kind,',' order by kind) as kinds,
           count(*)::bigint as reference_rows
      from referenced
     group by category_id
)
select format(
    'CATEGORY_TARGET_PROVENANCE|target_id=%s|target_user=%s|code=%s|parent_id=%s|parent_code=%s|is_active=%s|template_exact_count=%s|template_ids=%s|template_parent_code=%s|global_same_code_count=%s|reference_rows=%s|referencing_row_users=%s|kinds=%s',
    c.id,
    c.user_id,
    coalesce(c.code,''),
    coalesce(c.parent_id::text,''),
    coalesce(parent.code,''),
    coalesce(c.is_active,true),
    coalesce(tpl.template_count,0),
    coalesce(tpl.template_ids,''),
    coalesce(tpl.template_parent_code,''),
    coalesce(glob.global_count,0),
    g.reference_rows,
    g.row_users,
    g.kinds
)
from grouped g
join moneytrack.category_catalog c on c.id=g.category_id
left join moneytrack.category_catalog parent on parent.id=c.parent_id
left join lateral (
    select
        count(*)::bigint as template_count,
        string_agg(x.id::text,',' order by x.id) as template_ids,
        min(tp.code) as template_parent_code
    from moneytrack.category_catalog x
    left join moneytrack.category_catalog tp on tp.id=x.parent_id
    where x.user_id=0 and x.code is not distinct from c.code
) tpl on true
left join lateral (
    select count(*)::bigint as global_count
    from moneytrack.category_catalog x
    where x.code is not distinct from c.code
) glob on true
order by c.id;

-- ---------------------------------------------------------------------------
-- 4. Cluster receipt/product evidence by receipt owner and foreign category.
-- This shows whether dozens of FK findings are one capture cluster.
-- ---------------------------------------------------------------------------
select format(
    'RECEIPT_CATEGORY_CLUSTER|row_user=%s|target_category_id=%s|target_user=%s|target_code=%s|receipt_count=%s|receipt_ids=%s|item_count=%s',
    r.user_id,
    c.id,
    c.user_id,
    coalesce(c.code,''),
    count(distinct r.id),
    string_agg(distinct r.id::text,',' order by r.id::text),
    count(*)
)
from moneytrack.receipt_items ri
join moneytrack.receipts r on r.id=ri.receipt_id
join moneytrack.category_catalog c on c.id=ri.category_id
where ri.category_id is not null
  and c.user_id is distinct from r.user_id
group by r.user_id,c.id,c.user_id,c.code
order by r.user_id,c.id;

-- ---------------------------------------------------------------------------
-- 5. Compact facts used by the next migration decision.
-- ---------------------------------------------------------------------------
select 'CROSS_USER_TX_RECEIPT_OWNER_MISMATCH=' || count(*)
from moneytrack.transactions t
join moneytrack.accounts a on a.id=t.account_id
join moneytrack.receipts r on r.transaction_id=t.id
where a.user_id is distinct from t.user_id
  and r.user_id is distinct from t.user_id;

select 'CROSS_USER_ACCOUNT_TARGET_NOT_TEMPLATE_BACKED=' || count(*)
from (
    select distinct a.id,a.code
    from moneytrack.transactions t
    join moneytrack.accounts a on a.id=t.account_id
    where a.user_id is distinct from t.user_id
) q
where (select count(*) from moneytrack.accounts x where x.user_id=0 and x.code is not distinct from q.code) <> 1;

with target_categories as (
    select distinct c.id,c.code
      from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id
     where ri.category_id is not null and c.user_id is distinct from r.user_id
    union
    select distinct c.id,c.code
      from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id
     where p.category_id is not null and c.user_id is distinct from p.user_id
    union
    select distinct c.id,c.code
      from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id
     where b.category_id is not null and c.user_id is distinct from b.user_id
)
select 'CROSS_USER_CATEGORY_TARGET_NOT_TEMPLATE_BACKED=' || count(*)
from target_categories q
where (select count(*) from moneytrack.category_catalog x where x.user_id=0 and x.code is not distinct from q.code) <> 1;

select 'SPC001_REFERENCE_PROVENANCE_DIAGNOSTIC=END';
rollback;
