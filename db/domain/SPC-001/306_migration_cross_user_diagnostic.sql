-- MoneyTrack — SPC-001D — legacy cross-user reference diagnostic
-- READ ONLY. This report explains preflight cross-user findings and determines
-- whether each reference has exactly one owner-local equivalent by the same
-- canonical bootstrap key (account/category code). It performs no mutation.

\set ON_ERROR_STOP on
begin transaction read only;
\pset tuples_only on
\pset format unaligned

select 'SPC001_CROSS_USER_DIAGNOSTIC=BEGIN';

-- Transaction -> account. Space bootstrap clones accounts by code.
select format(
    'CROSS_USER|transaction_account|transaction_id=%s|row_user=%s|target_id=%s|target_user=%s|target_code=%s|target_name=%s|candidate_count=%s|candidate_ids=%s',
    t.id,
    t.user_id,
    a.id,
    a.user_id,
    coalesce(a.code,''),
    replace(coalesce(a.name,''),'|','/'),
    coalesce(c.candidate_count,0),
    coalesce(c.candidate_ids,'')
)
from moneytrack.transactions t
join moneytrack.accounts a on a.id=t.account_id
left join lateral (
    select
        count(*)::bigint as candidate_count,
        string_agg(x.id::text,',' order by x.id) as candidate_ids
    from moneytrack.accounts x
    where x.user_id=t.user_id
      and x.code is not distinct from a.code
) c on true
where a.user_id is distinct from t.user_id
order by t.id;

-- Receipt item -> category. The owning user is inherited from the receipt;
-- Space bootstrap clones categories by code.
select format(
    'CROSS_USER|receipt_item_category|receipt_item_id=%s|receipt_id=%s|row_user=%s|target_id=%s|target_user=%s|target_code=%s|candidate_count=%s|candidate_ids=%s',
    ri.id,
    r.id,
    r.user_id,
    c0.id,
    c0.user_id,
    coalesce(c0.code,''),
    coalesce(c.candidate_count,0),
    coalesce(c.candidate_ids,'')
)
from moneytrack.receipt_items ri
join moneytrack.receipts r on r.id=ri.receipt_id
join moneytrack.category_catalog c0 on c0.id=ri.category_id
left join lateral (
    select
        count(*)::bigint as candidate_count,
        string_agg(x.id::text,',' order by x.id) as candidate_ids
    from moneytrack.category_catalog x
    where x.user_id=r.user_id
      and x.code is not distinct from c0.code
) c on true
where ri.category_id is not null
  and c0.user_id is distinct from r.user_id
order by ri.id;

-- Product -> category. Product ownership determines the future product Space.
select format(
    'CROSS_USER|product_category|product_id=%s|row_user=%s|product_key=%s|target_id=%s|target_user=%s|target_code=%s|candidate_count=%s|candidate_ids=%s',
    p.id,
    p.user_id,
    replace(coalesce(p.product_key,''),'|','/'),
    c0.id,
    c0.user_id,
    coalesce(c0.code,''),
    coalesce(c.candidate_count,0),
    coalesce(c.candidate_ids,'')
)
from moneytrack.product_catalog p
join moneytrack.category_catalog c0 on c0.id=p.category_id
left join lateral (
    select
        count(*)::bigint as candidate_count,
        string_agg(x.id::text,',' order by x.id) as candidate_ids
    from moneytrack.category_catalog x
    where x.user_id=p.user_id
      and x.code is not distinct from c0.code
) c on true
where p.category_id is not null
  and c0.user_id is distinct from p.user_id
order by p.id;

-- Budget -> category. Budget ownership determines the future budget Space.
select format(
    'CROSS_USER|budget_category|budget_id=%s|row_user=%s|target_id=%s|target_user=%s|target_code=%s|candidate_count=%s|candidate_ids=%s',
    b.id,
    b.user_id,
    c0.id,
    c0.user_id,
    coalesce(c0.code,''),
    coalesce(c.candidate_count,0),
    coalesce(c.candidate_ids,'')
)
from moneytrack.budget_rules b
join moneytrack.category_catalog c0 on c0.id=b.category_id
left join lateral (
    select
        count(*)::bigint as candidate_count,
        string_agg(x.id::text,',' order by x.id) as candidate_ids
    from moneytrack.category_catalog x
    where x.user_id=b.user_id
      and x.code is not distinct from c0.code
) c on true
where b.category_id is not null
  and c0.user_id is distinct from b.user_id
order by b.id;

-- Compact classification: SAFE means every currently reported cross-user row
-- has exactly one owner-local candidate by the same canonical code.
with findings as (
    select 'transaction_account'::text as kind,
           t.id as row_id,
           (select count(*) from moneytrack.accounts x
             where x.user_id=t.user_id and x.code is not distinct from a.code) as candidate_count
      from moneytrack.transactions t
      join moneytrack.accounts a on a.id=t.account_id
     where a.user_id is distinct from t.user_id
    union all
    select 'receipt_item_category',ri.id,
           (select count(*) from moneytrack.category_catalog x
             where x.user_id=r.user_id and x.code is not distinct from c0.code)
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.category_catalog c0 on c0.id=ri.category_id
     where ri.category_id is not null and c0.user_id is distinct from r.user_id
    union all
    select 'product_category',p.id,
           (select count(*) from moneytrack.category_catalog x
             where x.user_id=p.user_id and x.code is not distinct from c0.code)
      from moneytrack.product_catalog p
      join moneytrack.category_catalog c0 on c0.id=p.category_id
     where p.category_id is not null and c0.user_id is distinct from p.user_id
    union all
    select 'budget_category',b.id,
           (select count(*) from moneytrack.category_catalog x
             where x.user_id=b.user_id and x.code is not distinct from c0.code)
      from moneytrack.budget_rules b
      join moneytrack.category_catalog c0 on c0.id=b.category_id
     where b.category_id is not null and c0.user_id is distinct from b.user_id
)
select format(
    'CROSS_USER_SUMMARY|kind=%s|rows=%s|unique_candidate=%s|missing_candidate=%s|ambiguous_candidate=%s',
    kind,
    count(*),
    count(*) filter(where candidate_count=1),
    count(*) filter(where candidate_count=0),
    count(*) filter(where candidate_count>1)
)
from findings
group by kind
order by kind;

with findings as (
    select (select count(*) from moneytrack.accounts x where x.user_id=t.user_id and x.code is not distinct from a.code) as candidate_count
      from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
     where a.user_id is distinct from t.user_id
    union all
    select (select count(*) from moneytrack.category_catalog x where x.user_id=r.user_id and x.code is not distinct from c0.code)
      from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c0 on c0.id=ri.category_id
     where ri.category_id is not null and c0.user_id is distinct from r.user_id
    union all
    select (select count(*) from moneytrack.category_catalog x where x.user_id=p.user_id and x.code is not distinct from c0.code)
      from moneytrack.product_catalog p join moneytrack.category_catalog c0 on c0.id=p.category_id
     where p.category_id is not null and c0.user_id is distinct from p.user_id
    union all
    select (select count(*) from moneytrack.category_catalog x where x.user_id=b.user_id and x.code is not distinct from c0.code)
      from moneytrack.budget_rules b join moneytrack.category_catalog c0 on c0.id=b.category_id
     where b.category_id is not null and c0.user_id is distinct from b.user_id
)
select 'SPC001_CROSS_USER_DETERMINISTIC_REMAP=' ||
       case when coalesce(bool_and(candidate_count=1),true) then 'PASS' else 'BLOCKED' end
from findings;

select 'SPC001_CROSS_USER_DIAGNOSTIC=END';
rollback;
