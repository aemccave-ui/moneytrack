-- MoneyTrack — UX-022R3 — read-only legacy grouping migration audit
-- Prints every parent that still owns direct history and its eligible same-currency
-- direct leaf children. No financial row is mutated by this file.

\echo '=== UX022R3 GROUPING MIGRATION AUDIT ==='

with legacy_parents as (
    select
        a.id as parent_id,
        a.user_id,
        a.name as parent_name,
        upper(a.currency_code) as currency_code,
        (select count(*) from moneytrack.transactions t
          where t.user_id = a.user_id and t.account_id = a.id)::bigint as transaction_count,
        (select count(*) from moneytrack.transfers tr
          where tr.user_id = a.user_id
            and (tr.from_account_id = a.id or tr.to_account_id = a.id))::bigint as transfer_count
    from moneytrack.accounts a
    where coalesce(a.is_active, true) = true
      and exists (
          select 1 from moneytrack.accounts child
          where child.user_id = a.user_id
            and child.parent_id = a.id
            and coalesce(child.is_active, true) = true
      )
      and (
          exists (select 1 from moneytrack.transactions t where t.user_id = a.user_id and t.account_id = a.id)
          or exists (
              select 1 from moneytrack.transfers tr
              where tr.user_id = a.user_id
                and (tr.from_account_id = a.id or tr.to_account_id = a.id)
          )
      )
), candidates as (
    select
        p.parent_id,
        p.user_id,
        p.parent_name,
        p.currency_code,
        p.transaction_count,
        p.transfer_count,
        child.id as target_id,
        child.name as target_name,
        child.sort_order,
        exists (
            select 1 from moneytrack.transfers tr
            where tr.user_id = p.user_id
              and ((tr.from_account_id = p.parent_id and tr.to_account_id = child.id)
                or (tr.to_account_id = p.parent_id and tr.from_account_id = child.id))
        ) as collapses_parent_child_transfer,
        exists (
            select 1 from moneytrack.transactions src
            where src.user_id = p.user_id
              and src.account_id = p.parent_id
              and src.transaction_type = 'openingbalance'
        ) and exists (
            select 1 from moneytrack.transactions dst
            where dst.user_id = p.user_id
              and dst.account_id = child.id
              and dst.transaction_type = 'openingbalance'
        ) as opening_balance_conflict
    from legacy_parents p
    left join moneytrack.accounts child
      on child.user_id = p.user_id
     and child.parent_id = p.parent_id
     and coalesce(child.is_active, true) = true
     and upper(child.currency_code) = p.currency_code
     and not exists (
         select 1 from moneytrack.accounts grandchild
         where grandchild.user_id = child.user_id
           and grandchild.parent_id = child.id
           and coalesce(grandchild.is_active, true) = true
     )
)
select
    parent_id,
    parent_name,
    currency_code,
    max(transaction_count) as parent_transactions,
    max(transfer_count) as parent_transfers,
    count(target_id) as candidate_count,
    coalesce(
        jsonb_agg(
            jsonb_build_object(
                'id', target_id,
                'name', target_name,
                'sort_order', sort_order,
                'transfer_conflict', collapses_parent_child_transfer,
                'opening_balance_conflict', opening_balance_conflict
            ) order by sort_order nulls last, target_id
        ) filter (where target_id is not null),
        '[]'::jsonb
    ) as candidates
from candidates
group by parent_id, parent_name, currency_code
order by parent_id;

-- Stop before the migration body when target selection is not deterministic.
do $audit$
declare
    v_bad_count bigint;
begin
    with legacy_parents as (
        select a.id, a.user_id, upper(a.currency_code) as currency_code
        from moneytrack.accounts a
        where coalesce(a.is_active, true) = true
          and exists (
              select 1 from moneytrack.accounts child
              where child.user_id = a.user_id
                and child.parent_id = a.id
                and coalesce(child.is_active, true) = true
          )
          and (
              exists (select 1 from moneytrack.transactions t where t.user_id = a.user_id and t.account_id = a.id)
              or exists (
                  select 1 from moneytrack.transfers tr
                  where tr.user_id = a.user_id
                    and (tr.from_account_id = a.id or tr.to_account_id = a.id)
              )
          )
    ), target_counts as (
        select p.id as parent_id, count(child.id) as candidate_count
        from legacy_parents p
        left join moneytrack.accounts child
          on child.user_id = p.user_id
         and child.parent_id = p.id
         and coalesce(child.is_active, true) = true
         and upper(child.currency_code) = p.currency_code
         and not exists (
             select 1 from moneytrack.accounts grandchild
             where grandchild.user_id = child.user_id
               and grandchild.parent_id = child.id
               and coalesce(grandchild.is_active, true) = true
         )
        group by p.id
    )
    select count(*) into v_bad_count
    from target_counts
    where candidate_count <> 1;

    if v_bad_count > 0 then
        raise exception 'ACCOUNT_GROUPING_MIGRATION_AUDIT_REQUIRES_TARGET_DECISION: % parent(s)', v_bad_count
            using errcode = '23514';
    end if;
end;
$audit$;

\echo 'UX022R3_GROUPING_MIGRATION_AUDIT=PASS'
