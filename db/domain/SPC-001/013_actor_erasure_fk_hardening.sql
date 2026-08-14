-- MoneyTrack — SPC-001A — authorship FK erasure hardening
--
-- Shared finance history must survive user erasure. Actor references therefore
-- cannot RESTRICT deletion of the identity row. NULL means an erased actor;
-- Space ownership and the financial record remain intact.

begin;

do $drop_actor_fks$
declare
    r record;
begin
    for r in
        select c.conrelid::regclass as rel, c.conname
        from pg_constraint c
        join pg_attribute a
          on a.attrelid=c.conrelid
         and a.attnum=any(c.conkey)
        where c.contype='f'
          and c.connamespace='moneytrack'::regnamespace
          and a.attname in ('created_by_user_id','updated_by_user_id','captured_by_user_id')
          and c.confrelid='moneytrack.app_users'::regclass
    loop
        execute format('alter table %s drop constraint %I',r.rel,r.conname);
    end loop;
end;
$drop_actor_fks$;

alter table moneytrack.accounts
    add constraint fk_spc001_accounts_created_by foreign key(created_by_user_id) references moneytrack.app_users(id) on delete set null,
    add constraint fk_spc001_accounts_updated_by foreign key(updated_by_user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.transactions
    add constraint fk_spc001_transactions_created_by foreign key(created_by_user_id) references moneytrack.app_users(id) on delete set null,
    add constraint fk_spc001_transactions_updated_by foreign key(updated_by_user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.transfers
    add constraint fk_spc001_transfers_created_by foreign key(created_by_user_id) references moneytrack.app_users(id) on delete set null,
    add constraint fk_spc001_transfers_updated_by foreign key(updated_by_user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.receipts
    add constraint fk_spc001_receipts_captured_by foreign key(captured_by_user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.category_catalog
    add constraint fk_spc001_categories_created_by foreign key(created_by_user_id) references moneytrack.app_users(id) on delete set null,
    add constraint fk_spc001_categories_updated_by foreign key(updated_by_user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.product_catalog
    add constraint fk_spc001_products_created_by foreign key(created_by_user_id) references moneytrack.app_users(id) on delete set null,
    add constraint fk_spc001_products_updated_by foreign key(updated_by_user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.budget_rules
    add constraint fk_spc001_budgets_created_by foreign key(created_by_user_id) references moneytrack.app_users(id) on delete set null,
    add constraint fk_spc001_budgets_updated_by foreign key(updated_by_user_id) references moneytrack.app_users(id) on delete set null;

comment on column moneytrack.transactions.created_by_user_id
is 'Original actor while identity exists; becomes NULL only after explicit user erasure. Financial history remains Space-owned.';

commit;
