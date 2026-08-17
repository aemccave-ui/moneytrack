-- MoneyTrack — UX-025B — inverse schema rollback
-- Safe only after the UX-025 financial workflow has been restored to the
-- accepted SPC-001 dispatcher. Does not touch category data or SPC functions.
\set ON_ERROR_STOP on

begin;

drop function if exists moneytrack.ux025_financial_api_dispatch_v1(bigint,bigint,text,text,jsonb,jsonb);
drop function if exists moneytrack.category_delete_space_v1(bigint,bigint,bigint);
drop function if exists moneytrack.category_reorder_space_v1(bigint,bigint,bigint,text);
drop function if exists moneytrack.category_reorder_space_v1(bigint,bigint,bigint,integer);
drop function if exists moneytrack.category_edit_space_v1(bigint,bigint,bigint,text,text,bigint,integer);
drop function if exists moneytrack.category_create_space_v1(bigint,bigint,text,text,bigint,integer);
drop function if exists moneytrack.category_directory_space_v1(bigint,bigint);

commit;
