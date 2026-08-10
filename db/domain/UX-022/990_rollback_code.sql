-- UX-022 code/schema rollback.
-- Deliberately retains moneytrack.filter_presets data/table: rollback must not
-- destroy user data. Restored workflows must be imported before this file runs.

begin;

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
drop function if exists moneytrack.ux022_account_own_balance_original_v1(bigint,bigint,timestamptz);

drop function if exists moneytrack.filter_preset_delete_v1(bigint,bigint);
drop function if exists moneytrack.filter_preset_rename_v1(bigint,bigint,text);
drop function if exists moneytrack.filter_preset_create_v1(bigint,text,bigint[],bigint[],bigint[]);
drop function if exists moneytrack.filter_presets_read_v1(bigint);
drop function if exists moneytrack.ux022_resolve_user_id_v1(bigint);

commit;
