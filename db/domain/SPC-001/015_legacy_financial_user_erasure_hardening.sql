-- MoneyTrack — SPC-001A — legacy financial user_id erasure hardening
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- After SPC cutover, financial ownership is space_id. Legacy user_id columns are
-- compatibility/actor provenance only and must not cascade-delete or RESTRICT
-- shared Space history when an identity is erased.

begin;

-- Non-template Space-owned financial rows may outlive the actor identity.
alter table moneytrack.accounts alter column user_id drop not null;
alter table moneytrack.transactions alter column user_id drop not null;
alter table moneytrack.transfers alter column user_id drop not null;
alter table moneytrack.receipts alter column user_id drop not null;
alter table moneytrack.category_catalog alter column user_id drop not null;
alter table moneytrack.product_catalog alter column user_id drop not null;
alter table moneytrack.budget_rules alter column user_id drop not null;

-- Drop only FKs from the legacy financial user_id columns to app_users.
do $drop_legacy_user_fks$
declare
    r record;
begin
    for r in
        select c.conrelid::regclass as rel, c.conname
        from pg_constraint c
        join lateral unnest(c.conkey) with ordinality u(attnum,ord) on true
        join pg_attribute a
          on a.attrelid=c.conrelid
         and a.attnum=u.attnum
        where c.contype='f'
          and c.connamespace='moneytrack'::regnamespace
          and c.confrelid='moneytrack.app_users'::regclass
          and a.attname='user_id'
          and c.conrelid in (
              'moneytrack.accounts'::regclass,
              'moneytrack.transactions'::regclass,
              'moneytrack.transfers'::regclass,
              'moneytrack.receipts'::regclass,
              'moneytrack.category_catalog'::regclass,
              'moneytrack.product_catalog'::regclass,
              'moneytrack.budget_rules'::regclass
          )
        group by c.conrelid,c.conname
    loop
        execute format('alter table %s drop constraint %I',r.rel,r.conname);
    end loop;
end;
$drop_legacy_user_fks$;

alter table moneytrack.accounts
    add constraint fk_spc001_accounts_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.transactions
    add constraint fk_spc001_transactions_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.transfers
    add constraint fk_spc001_transfers_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.receipts
    add constraint fk_spc001_receipts_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.category_catalog
    add constraint fk_spc001_categories_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.product_catalog
    add constraint fk_spc001_products_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;
alter table moneytrack.budget_rules
    add constraint fk_spc001_budgets_legacy_user
    foreign key(user_id) references moneytrack.app_users(id) on delete set null;

comment on column moneytrack.transactions.user_id
is 'SPC-001 legacy compatibility/actor provenance only; financial tenant is space_id. May become NULL after actor erasure.';
comment on column moneytrack.accounts.user_id
is 'SPC-001 legacy compatibility/actor provenance only; financial tenant is space_id. May become NULL after actor erasure.';
comment on column moneytrack.category_catalog.user_id
is 'SPC-001 legacy compatibility/actor provenance only; financial tenant is space_id. User 0 remains the global template sentinel.';

commit;
