-- UX-022 code/schema rollback.
-- Deliberately retains moneytrack.filter_presets data/table: rollback must not
-- destroy user data. Restored workflows must be imported before this file runs.

begin;

-- Disable R3 guards before restoring journaled legacy ownership.
drop trigger if exists ux022_transfers_group_posting_guard on moneytrack.transfers;
drop trigger if exists ux022_transactions_group_posting_guard on moneytrack.transactions;
drop trigger if exists ux022_accounts_parent_group_guard on moneytrack.accounts;

-- Reverse the one-time grouping normalization when its journals exist.
do $block$
declare
    v_ref record;
    v_type_name text;
    v_remaining bigint;
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

    if to_regclass('moneytrack.ux022_grouping_user_default_migration_backup') is not null
       and to_regclass('moneytrack.user_default_accounts') is not null
    then
        execute $sql$
            update moneytrack.user_default_accounts d
               set account_id = b.original_account_id
              from moneytrack.ux022_grouping_user_default_migration_backup b
             where d.user_id = b.user_id
               and d.currency_code = b.currency_code
               and d.account_id = b.target_account_id
        $sql$;
    end if;

    if to_regclass('moneytrack.ux022_grouping_user_settings_migration_backup') is not null then
        for v_ref in
            select user_id, column_name, original_account_id, target_account_id
            from moneytrack.ux022_grouping_user_settings_migration_backup
            order by user_id, column_name
        loop
            select format_type(a.atttypid, a.atttypmod)
              into v_type_name
              from pg_attribute a
              join pg_class c on c.oid = a.attrelid
              join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = 'moneytrack'
               and c.relname = 'user_settings'
               and a.attname = v_ref.column_name
               and a.attnum > 0
               and not a.attisdropped;

            if v_type_name is not null then
                execute format(
                    'update moneytrack.user_settings set %I = ($1::text)::%s '
                    || 'where user_id=$2 and (%I)::text=$3',
                    v_ref.column_name,
                    v_type_name,
                    v_ref.column_name
                )
                using v_ref.original_account_id, v_ref.user_id, v_ref.target_account_id::text;
            end if;
        end loop;
    end if;

    -- A fallback child may only be removed if nothing new was posted to it after
    -- the migration. Fail closed instead of deleting post-migration user data.
    if to_regclass('moneytrack.ux022_grouping_created_account_migration_backup') is not null then
        select count(*)
          into v_remaining
          from moneytrack.ux022_grouping_created_account_migration_backup b
         where exists (
                select 1 from moneytrack.transactions t
                where t.user_id = b.user_id and t.account_id = b.account_id
         ) or exists (
                select 1 from moneytrack.transfers tr
                where tr.user_id = b.user_id
                  and (tr.from_account_id = b.account_id or tr.to_account_id = b.account_id)
         ) or exists (
                select 1 from moneytrack.accounts child
                where child.user_id = b.user_id and child.parent_id = b.account_id
         ) or moneytrack.ux022_account_is_default_v1(b.user_id, b.account_id);

        if v_remaining > 0 then
            raise exception 'UX022R3_ROLLBACK_FALLBACK_ACCOUNT_HAS_NEW_REFERENCES: %', v_remaining
                using errcode = '23514';
        end if;

        delete from moneytrack.accounts a
        using moneytrack.ux022_grouping_created_account_migration_backup b
        where a.id = b.account_id
          and a.user_id = b.user_id;
    end if;
end;
$block$;

drop table if exists moneytrack.ux022_grouping_user_settings_migration_backup;
drop table if exists moneytrack.ux022_grouping_user_default_migration_backup;
drop table if exists moneytrack.ux022_grouping_created_account_migration_backup;
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
