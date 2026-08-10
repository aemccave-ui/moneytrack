-- MoneyTrack — UX-022R3 — isolated grouping-account rollback
-- Reverts only the R3 grouping normalization/invariant. It deliberately does NOT
-- remove the rest of UX-022. The rollback fails closed if journaled rows or a
-- migration-created fallback account were modified after the R3 apply.

begin;

-- Stop the R3 invariant while restoring the pre-R3 ownership model.
drop trigger if exists ux022_transfers_group_posting_guard on moneytrack.transfers;
drop trigger if exists ux022_transactions_group_posting_guard on moneytrack.transactions;
drop trigger if exists ux022_accounts_parent_group_guard on moneytrack.accounts;

-- Fail closed when a journaled transaction no longer points at the migration target.
do $block$
begin
    if to_regclass('moneytrack.ux022_grouping_transaction_migration_backup') is not null
       and exists (
            select 1
            from moneytrack.ux022_grouping_transaction_migration_backup b
            join moneytrack.transactions t
              on t.id = b.transaction_id
             and t.user_id = b.user_id
            where t.account_id <> b.target_account_id
       )
    then
        raise exception 'UX022R3_ROLLBACK_TRANSACTION_CHANGED_AFTER_MIGRATION'
            using errcode = '55000';
    end if;

    if to_regclass('moneytrack.ux022_grouping_transfer_migration_backup') is not null
       and exists (
            select 1
            from moneytrack.ux022_grouping_transfer_migration_backup b
            join moneytrack.transfers tr
              on tr.id = b.transfer_id
             and tr.user_id = b.user_id
            where tr.from_account_id not in (b.original_from_account_id, b.target_account_id)
               or tr.to_account_id not in (b.original_to_account_id, b.target_account_id)
       )
    then
        raise exception 'UX022R3_ROLLBACK_TRANSFER_CHANGED_AFTER_MIGRATION'
            using errcode = '55000';
    end if;
end;
$block$;

-- Restore financial history.
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

-- Restore canonical per-currency defaults, but fail closed if a user changed the
-- default after migration rather than overwriting that new choice silently.
do $block$
begin
    if to_regclass('moneytrack.ux022_grouping_user_default_migration_backup') is not null
       and to_regclass('moneytrack.user_default_accounts') is not null
    then
        if exists (
            select 1
            from moneytrack.ux022_grouping_user_default_migration_backup b
            join moneytrack.user_default_accounts d
              on d.user_id = b.user_id
             and d.currency_code = b.currency_code
            where d.account_id <> b.target_account_id
        ) then
            raise exception 'UX022R3_ROLLBACK_DEFAULT_CHANGED_AFTER_MIGRATION'
                using errcode = '55000';
        end if;

        update moneytrack.user_default_accounts d
           set account_id = b.original_account_id
          from moneytrack.ux022_grouping_user_default_migration_backup b
         where d.user_id = b.user_id
           and d.currency_code = b.currency_code
           and d.account_id = b.target_account_id;
    end if;
end;
$block$;

-- Restore schema-tolerant user_settings account defaults.
do $block$
declare
    v_row record;
    v_type_name text;
    v_current text;
begin
    if to_regclass('moneytrack.ux022_grouping_user_settings_migration_backup') is null then
        return;
    end if;

    for v_row in
        select *
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
           and a.attname = v_row.column_name
           and a.attnum > 0
           and not a.attisdropped;

        if v_type_name is null then
            raise exception 'UX022R3_ROLLBACK_SETTINGS_COLUMN_MISSING: %', v_row.column_name
                using errcode = '55000';
        end if;

        execute format(
            'select (%I)::text from moneytrack.user_settings where user_id=$1',
            v_row.column_name
        ) into v_current using v_row.user_id;

        if v_current is distinct from v_row.target_account_id::text then
            raise exception 'UX022R3_ROLLBACK_SETTINGS_CHANGED_AFTER_MIGRATION: user_id=% column=%',
                v_row.user_id, v_row.column_name
                using errcode = '55000';
        end if;

        execute format(
            'update moneytrack.user_settings set %I = ($1::text)::%s where user_id=$2',
            v_row.column_name,
            v_type_name
        ) using v_row.original_account_id, v_row.user_id;
    end loop;
end;
$block$;

-- Migration-created fallback leaves are removed only when nothing new references
-- them after the journaled history/defaults have been restored.
do $block$
declare
    v_row record;
    v_col record;
    v_in_use boolean;
begin
    if to_regclass('moneytrack.ux022_grouping_created_account_migration_backup') is null then
        return;
    end if;

    for v_row in
        select *
        from moneytrack.ux022_grouping_created_account_migration_backup
        order by account_id
    loop
        v_in_use := exists (
            select 1 from moneytrack.transactions t
            where t.user_id = v_row.user_id and t.account_id = v_row.account_id
        ) or exists (
            select 1 from moneytrack.transfers tr
            where tr.user_id = v_row.user_id
              and (tr.from_account_id = v_row.account_id or tr.to_account_id = v_row.account_id)
        ) or exists (
            select 1 from moneytrack.accounts child
            where child.user_id = v_row.user_id and child.parent_id = v_row.account_id
        );

        if not v_in_use and to_regclass('moneytrack.user_default_accounts') is not null then
            execute 'select exists (select 1 from moneytrack.user_default_accounts where user_id=$1 and account_id=$2)'
              into v_in_use using v_row.user_id, v_row.account_id;
        end if;

        if not v_in_use then
            for v_col in
                select a.attname as column_name
                from pg_attribute a
                join pg_class c on c.oid = a.attrelid
                join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'moneytrack'
                  and c.relname = 'user_settings'
                  and a.attnum > 0
                  and not a.attisdropped
                  and (
                        a.attname = 'setdefaultaccount'
                     or a.attname like '%account_id%'
                     or lower(a.attname) like '%accountid%'
                  )
            loop
                execute format(
                    'select exists (select 1 from moneytrack.user_settings where user_id=$1 and (%I)::text=$2)',
                    v_col.column_name
                ) into v_in_use using v_row.user_id, v_row.account_id::text;
                exit when v_in_use;
            end loop;
        end if;

        if v_in_use then
            raise exception 'UX022R3_ROLLBACK_FALLBACK_ACCOUNT_IN_USE: account_id=%', v_row.account_id
                using errcode = '55000';
        end if;

        delete from moneytrack.accounts a
        where a.id = v_row.account_id
          and a.user_id = v_row.user_id
          and a.parent_id = v_row.parent_account_id;
    end loop;
end;
$block$;

-- Remove only R3 objects after successful data restoration.
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

commit;
