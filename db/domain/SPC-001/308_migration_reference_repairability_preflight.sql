-- MoneyTrack — SPC-001D — legacy cross-user reference repairability preflight
-- READ ONLY. This does not bless arbitrary cross-user data. It allows the
-- controlled migration to proceed only when the known reference classes can be
-- deterministically severed into the owning user's future Personal Space.

\set ON_ERROR_STOP on
begin transaction read only;
\pset tuples_only on
\pset format unaligned

do $repairability$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
begin
    -- Cross-user classes that are NOT covered by the repair stay fail-closed.
    select count(*) into v_count
      from moneytrack.accounts a
      join moneytrack.accounts p on p.id=a.parent_id
     where a.parent_id is not null and p.user_id is distinct from a.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'account_parent_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.category_catalog c
      join moneytrack.category_catalog p on p.id=c.parent_id
     where c.parent_id is not null and p.user_id is distinct from c.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'category_parent_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions t
      join moneytrack.category_catalog c on c.id=t.category_id
     where t.category_id is not null and c.user_id is distinct from t.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_category_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transfers t
      join moneytrack.accounts a1 on a1.id=t.from_account_id
      join moneytrack.accounts a2 on a2.id=t.to_account_id
     where a1.user_id is distinct from t.user_id or a2.user_id is distinct from t.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfer_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipts r
      join moneytrack.transactions t on t.id=r.transaction_id
     where t.user_id is distinct from r.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_transaction_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.product_catalog p on p.id=ri.product_id
     where ri.product_id is not null and p.user_id is distinct from r.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_product_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.user_default_accounts d
      join moneytrack.accounts a on a.id=d.account_id
     where a.user_id is distinct from d.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.user_settings s
      join moneytrack.accounts a on a.id=s.default_expense_account_id
     where s.default_expense_account_id is not null and a.user_id is distinct from s.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_expense_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.user_settings s
      join moneytrack.accounts a on a.id=s.default_income_account_id
     where s.default_income_account_id is not null and a.user_id is distinct from s.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_income_account_cross_user='||v_count); end if;

    -- Every foreign account target must have a stable code, an acyclic/same-owner
    -- parent path, and at most one owner-local candidate by code.
    select count(*) into v_count
      from moneytrack.transactions t
      join moneytrack.accounts a on a.id=t.account_id
     where a.user_id is distinct from t.user_id
       and nullif(btrim(a.code),'') is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_account_code_missing='||v_count); end if;

    select count(*) into v_count
      from (
        select distinct t.user_id as target_user_id, a.code
          from moneytrack.transactions t
          join moneytrack.accounts a on a.id=t.account_id
         where a.user_id is distinct from t.user_id
      ) q
     where (select count(*) from moneytrack.accounts x where x.user_id=q.target_user_id and x.code is not distinct from q.code)>1;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_account_candidate_ambiguous='||v_count); end if;

    with recursive seeds as (
        select distinct a.id as source_id, a.user_id as source_user_id
          from moneytrack.transactions t
          join moneytrack.accounts a on a.id=t.account_id
         where a.user_id is distinct from t.user_id
    ), path as (
        select s.source_id, s.source_user_id, s.source_id as current_id,
               array[s.source_id]::bigint[] as seen, false as cycle
          from seeds s
        union all
        select p.source_id, p.source_user_id, parent.id,
               p.seen || parent.id,
               parent.id=any(p.seen)
          from path p
          join moneytrack.accounts cur on cur.id=p.current_id
          join moneytrack.accounts parent on parent.id=cur.parent_id
         where not p.cycle
    )
    select count(*) into v_count
      from path p
      join moneytrack.accounts a on a.id=p.current_id
     where p.cycle
        or a.user_id is distinct from p.source_user_id
        or nullif(btrim(a.code),'') is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_account_path_invalid='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions t
      join moneytrack.accounts src on src.id=t.account_id
      join moneytrack.accounts dst on dst.user_id=t.user_id and dst.code is not distinct from src.code
      left join moneytrack.accounts sp on sp.id=src.parent_id
      left join moneytrack.accounts dp on dp.id=dst.parent_id
     where src.user_id is distinct from t.user_id
       and (
           upper(dst.currency_code) is distinct from upper(src.currency_code)
        or lower(dst.account_type::text) is distinct from lower(src.account_type::text)
        or dp.code is distinct from sp.code
       );
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_account_candidate_incompatible='||v_count); end if;

    -- Category targets from receipt items/products/budgets use the same policy.
    select count(*) into v_count
      from (
        select c.id,c.code from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id where ri.category_id is not null and c.user_id is distinct from r.user_id
        union
        select c.id,c.code from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id where p.category_id is not null and c.user_id is distinct from p.user_id
        union
        select c.id,c.code from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id where b.category_id is not null and c.user_id is distinct from b.user_id
      ) q
     where nullif(btrim(q.code),'') is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_category_code_missing='||v_count); end if;

    select count(*) into v_count
      from (
        select distinct r.user_id as target_user_id,c.code from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id where ri.category_id is not null and c.user_id is distinct from r.user_id
        union
        select distinct p.user_id,c.code from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id where p.category_id is not null and c.user_id is distinct from p.user_id
        union
        select distinct b.user_id,c.code from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id where b.category_id is not null and c.user_id is distinct from b.user_id
      ) q
     where (select count(*) from moneytrack.category_catalog x where x.user_id=q.target_user_id and x.code is not distinct from q.code)>1;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_category_candidate_ambiguous='||v_count); end if;

    with recursive seeds as (
        select distinct c.id as source_id,c.user_id as source_user_id
          from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id
         where ri.category_id is not null and c.user_id is distinct from r.user_id
        union
        select distinct c.id,c.user_id from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id
         where p.category_id is not null and c.user_id is distinct from p.user_id
        union
        select distinct c.id,c.user_id from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id
         where b.category_id is not null and c.user_id is distinct from b.user_id
    ), path as (
        select s.source_id,s.source_user_id,s.source_id as current_id,array[s.source_id]::bigint[] as seen,false as cycle
          from seeds s
        union all
        select p.source_id,p.source_user_id,parent.id,p.seen||parent.id,parent.id=any(p.seen)
          from path p
          join moneytrack.category_catalog cur on cur.id=p.current_id
          join moneytrack.category_catalog parent on parent.id=cur.parent_id
         where not p.cycle
    )
    select count(*) into v_count
      from path p
      join moneytrack.category_catalog c on c.id=p.current_id
     where p.cycle
        or c.user_id is distinct from p.source_user_id
        or nullif(btrim(c.code),'') is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_category_path_invalid='||v_count); end if;

    with targets as (
        select distinct r.user_id as target_user_id,c.id as source_id from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id where ri.category_id is not null and c.user_id is distinct from r.user_id
        union
        select distinct p.user_id,c.id from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id where p.category_id is not null and c.user_id is distinct from p.user_id
        union
        select distinct b.user_id,c.id from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id where b.category_id is not null and c.user_id is distinct from b.user_id
    )
    select count(*) into v_count
      from targets q
      join moneytrack.category_catalog src on src.id=q.source_id
      join moneytrack.category_catalog dst on dst.user_id=q.target_user_id and dst.code is not distinct from src.code
      left join moneytrack.category_catalog sp on sp.id=src.parent_id
      left join moneytrack.category_catalog dp on dp.id=dst.parent_id
     where dp.code is distinct from sp.code
        or nullif(lower(dst.flow_type),'') is distinct from nullif(lower(src.flow_type),'');
    if v_count<>0 then v_errors:=array_append(v_errors,'repair_category_candidate_incompatible='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_REFERENCE_REPAIRABILITY_FAILED: %',array_to_string(v_errors,';');
    end if;
end;
$repairability$;

select 'REPAIRABLE|transaction_account='||count(*)
from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
where a.user_id is distinct from t.user_id;
select 'REPAIRABLE|receipt_item_category='||count(*)
from moneytrack.receipt_items ri join moneytrack.receipts r on r.id=ri.receipt_id join moneytrack.category_catalog c on c.id=ri.category_id
where ri.category_id is not null and c.user_id is distinct from r.user_id;
select 'REPAIRABLE|product_category='||count(*)
from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id
where p.category_id is not null and c.user_id is distinct from p.user_id;
select 'REPAIRABLE|budget_category='||count(*)
from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id
where b.category_id is not null and c.user_id is distinct from b.user_id;
select 'SPC001_REFERENCE_REPAIRABILITY_PREFLIGHT=PASS';
rollback;
