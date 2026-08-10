-- UX-022 code/schema rollback.
-- Deliberately retains moneytrack.filter_presets data/table: rollback must not
-- destroy user data. Restored workflows must be imported before this file runs.

begin;

-- Disable R3 guards before restoring journaled legacy ownership.
drop trigger if exists ux022_transfers_group_posting_guard on moneytrack.transfers;
drop trigger if exists ux022_transactions_group_posting_guard on moneytrack.transactions;
drop trigger if exists ux022_accounts_parent_group_guard on moneytrack.accounts;

-- Reverse the one-time grouping normalization when its journal exists.
do $block$
begin
    if to_regclass('moneytrack.ux022_grouping_transaction_migration_backup') is not null then
        execute $sql$
            update moneytrack.transactions t
               set account_id = b.original_account_id
              from moneytrack.ux022_grouping_transaction_migration_backup b
             where t.id = b.transaction_id
               and t.user_id = b.user_id
               and t.account_id = b.target_account_id
        $sql$;
    end if;

    if to_regclass('moneytrack.ux022_grouping_transfer_migration_backup') is not null then
        execute $sql$
            update moneytrack.transfers tr
               set from_account_id = b.original_from_account_id,
                   to_account_id = b.original_to_account_id
              from moneytrack.ux022_grouping_transfer_migration_backup b
             where tr.id = b.transfer_id
               and tr.user_id = b.user_id
        $sql$;
    end if;
end;
$block$;

drop table if exists moneytrack.ux022_grouping_transfer_migration_backup;
drop table if exists moneytrack.ux022_grouping_transaction_migration_backup;

drop function if exists moneytrack.ux022_guard_transfer_postable_accounts_v1();
drop function if exists moneytrack.ux022_guard_transaction_postable_account_v1();
drop function if exists moneytrack.ux022_guard_parent_account_v1();
drop function if exists moneytrack.ux022_account_has_active_children_v1(bigint,bigint);
drop function if exists moneytrack.ux022_account_has_direct_operations_v1(bigint,bigint);

drop function if exists moneytrack.api_transactions_read_model_v2(bigint,bigint,date,date,boolean,bigint[],bigint[],bigint[]);
drop function if exists moneytrack.api_accounts_explorer_summary_read_model_v2(bigint,bigint[],bigint[],bigint[],date,date,date);

drop function if exists moneytrack.accounts_archived_read_v1(bigint);
drop function if exists moneytrack.account_delete_v1(bigint,bigint);
drop function if exists moneytrack.account_restore_v1(bigint,bigint);
drop function if exists moneytrack.account_archive_v1(bigint,bigint);
drop function if exists moneytrack.account_move_operations_v1(bigint,bigint,bigint);
drop function if exists moneytrack.account_move_operations_preview_v1(bigint,bigint,bigint);
drop function if exists moneytrack.account_move_v1(bigint,bigint,bigint);
drop function if exists moneytrack.account_edit_v1(bigint,bigint,text,text);
drop function if exists moneytrack.account_copy_v1(bigint,bigint);
drop function if exists moneytrack.account_create_v1(bigint,text,text,text,bigint,text);
drop function if exists moneytrack.ux022_account_is_default_v1(bigint,bigint);
drop function if exists moneytrack.ux022_account_own_balance_original_v1(bigint,bigint,timestamptz);

drop function if exists moneytrack.filter_preset_delete_v1(bigint,bigint);
drop function if exists moneytrack.filter_preset_rename_v1(bigint,bigint,text);
drop function if exists moneytrack.filter_preset_create_v1(bigint,text,bigint[],bigint[],bigint[]);
drop function if exists moneytrack.filter_presets_read_v1(bigint);
drop function if exists moneytrack.ux022_resolve_user_id_v1(bigint);

commit;
