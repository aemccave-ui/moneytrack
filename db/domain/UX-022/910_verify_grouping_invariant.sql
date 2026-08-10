-- UX-022R3 grouping-account runtime verifier.
-- Executed only after the migration body inside the rollback-only migration gate.

do $verify$
declare
    v_violation_count bigint;
    v_trigger_count bigint;
begin
    select count(*)
      into v_violation_count
      from moneytrack.accounts a
     where coalesce(a.is_active, true) = true
       and moneytrack.ux022_account_has_active_children_v1(a.user_id, a.id)
       and moneytrack.ux022_account_has_direct_operations_v1(a.user_id, a.id);

    if v_violation_count <> 0 then
        raise exception 'UX022R3_VERIFY_GROUPING_DIRECT_OPERATIONS_REMAIN: %', v_violation_count;
    end if;

    select count(*)
      into v_trigger_count
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'moneytrack'
       and t.tgname in (
            'ux022_accounts_parent_group_guard',
            'ux022_transactions_group_posting_guard',
            'ux022_transfers_group_posting_guard'
       )
       and not t.tgisinternal
       and t.tgenabled <> 'D';

    if v_trigger_count <> 3 then
        raise exception 'UX022R3_VERIFY_GROUPING_TRIGGERS: expected=3 actual=%', v_trigger_count;
    end if;

    if to_regclass('moneytrack.ux022_grouping_transaction_migration_backup') is null
       or to_regclass('moneytrack.ux022_grouping_transfer_migration_backup') is null
    then
        raise exception 'UX022R3_VERIFY_GROUPING_ROLLBACK_JOURNAL_MISSING';
    end if;

    raise notice 'UX022R3_GROUPING_RUNTIME_VERIFY=PASS';
end;
$verify$;

select
    parent.id as parent_id,
    parent.name as parent_name,
    parent.currency_code as parent_currency,
    child.id as migration_target_id,
    child.name as migration_target_name,
    child.sort_order as migration_target_sort_order,
    (
        select count(*)
        from moneytrack.ux022_grouping_transaction_migration_backup b
        where b.original_account_id = parent.id
          and b.target_account_id = child.id
    ) as migrated_transactions,
    (
        select count(*)
        from moneytrack.ux022_grouping_transfer_migration_backup b
        where (b.original_from_account_id = parent.id or b.original_to_account_id = parent.id)
          and b.target_account_id = child.id
    ) as migrated_transfers
from moneytrack.accounts parent
join moneytrack.accounts child
  on child.parent_id = parent.id
 and child.user_id = parent.user_id
where exists (
    select 1
    from moneytrack.ux022_grouping_transaction_migration_backup b
    where b.original_account_id = parent.id
      and b.target_account_id = child.id
)
or exists (
    select 1
    from moneytrack.ux022_grouping_transfer_migration_backup b
    where (b.original_from_account_id = parent.id or b.original_to_account_id = parent.id)
      and b.target_account_id = child.id
)
order by parent.user_id, parent.id, child.sort_order nulls last, child.id;
