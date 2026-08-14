-- MoneyTrack — SPC-001A — tenancy uniqueness hardening
--
-- SOURCE ONLY until controlled SPC runtime apply.
-- Legacy financial uniqueness keyed by user_id encodes USER OWNS FINANCIAL MODEL
-- and would prevent one actor from having equivalent account/category/product
-- codes in independent Spaces. Replace only exact legacy financial uniqueness
-- keys; preserve a separate uniqueness rule for global/template rows.

begin;

-- ---------------------------------------------------------------------------
-- 1. Drop exact legacy UNIQUE constraints that encode user financial tenancy.
-- Constraint names are intentionally not assumed: canonical/runtime history may
-- have generated names. Only exact ordered column sets are eligible.
-- ---------------------------------------------------------------------------

do $drop_legacy_unique_constraints$
declare
    r record;
    v_cols text[];
begin
    for r in
        select c.oid, c.conrelid, c.conname, c.conkey
        from pg_constraint c
        where c.contype = 'u'
          and c.connamespace = 'moneytrack'::regnamespace
          and c.conrelid in (
              'moneytrack.accounts'::regclass,
              'moneytrack.category_catalog'::regclass,
              'moneytrack.product_catalog'::regclass
          )
    loop
        select array_agg(a.attname order by u.ord)
          into v_cols
          from unnest(r.conkey) with ordinality u(attnum, ord)
          join pg_attribute a
            on a.attrelid = r.conrelid
           and a.attnum = u.attnum;

        if (r.conrelid = 'moneytrack.accounts'::regclass
            and v_cols = array['user_id','code']::text[])
           or (r.conrelid = 'moneytrack.category_catalog'::regclass
            and v_cols = array['user_id','code']::text[])
           or (r.conrelid = 'moneytrack.product_catalog'::regclass
            and v_cols = array['user_id','product_key']::text[])
        then
            execute format(
                'alter table %s drop constraint %I',
                r.conrelid::regclass,
                r.conname
            );
        end if;
    end loop;
end;
$drop_legacy_unique_constraints$;

-- Some historical schemas may implement the same keys as standalone UNIQUE
-- indexes rather than constraints. Drop only exact, non-expression, non-partial
-- standalone indexes with the same legacy keys.
do $drop_legacy_unique_indexes$
declare
    r record;
    v_cols text[];
begin
    for r in
        select i.indexrelid, i.indrelid, i.indkey
        from pg_index i
        join pg_class idx on idx.oid = i.indexrelid
        join pg_namespace n on n.oid = idx.relnamespace
        where n.nspname = 'moneytrack'
          and i.indisunique
          and i.indexprs is null
          and i.indpred is null
          and i.indrelid in (
              'moneytrack.accounts'::regclass,
              'moneytrack.category_catalog'::regclass,
              'moneytrack.product_catalog'::regclass
          )
          and not exists (
              select 1 from pg_constraint c where c.conindid = i.indexrelid
          )
    loop
        select array_agg(a.attname order by u.ord)
          into v_cols
          from unnest(r.indkey::smallint[]) with ordinality u(attnum, ord)
          join pg_attribute a
            on a.attrelid = r.indrelid
           and a.attnum = u.attnum
         where u.attnum > 0;

        if (r.indrelid = 'moneytrack.accounts'::regclass
            and v_cols = array['user_id','code']::text[])
           or (r.indrelid = 'moneytrack.category_catalog'::regclass
            and v_cols = array['user_id','code']::text[])
           or (r.indrelid = 'moneytrack.product_catalog'::regclass
            and v_cols = array['user_id','product_key']::text[])
        then
            execute format('drop index %s', r.indexrelid::regclass);
        end if;
    end loop;
end;
$drop_legacy_unique_indexes$;

-- Known BE-DOM-001 idempotency indexes are also explicitly user-scoped.
-- Their Space-scoped replacements are created here/020.
drop index if exists moneytrack.ux_transactions_source_idempotency;
drop index if exists moneytrack.ux_transactions_one_opening_balance_per_account;
drop index if exists moneytrack.ux_transfers_source_idempotency;

-- ---------------------------------------------------------------------------
-- 2. Canonical Space uniqueness.
-- ---------------------------------------------------------------------------

create unique index if not exists ux_spc001_accounts_space_code
    on moneytrack.accounts(space_id, code)
    where space_id is not null;

create unique index if not exists ux_spc001_categories_space_code
    on moneytrack.category_catalog(space_id, code)
    where space_id is not null;

create unique index if not exists ux_spc001_products_space_key
    on moneytrack.product_catalog(space_id, product_key)
    where space_id is not null;

create unique index if not exists ux_spc001_transactions_space_source
    on moneytrack.transactions(space_id, source_type, source_id)
    where space_id is not null
      and source_type is not null
      and source_id is not null;

create unique index if not exists ux_spc001_transactions_space_opening_balance
    on moneytrack.transactions(space_id, account_id)
    where space_id is not null
      and transaction_type = 'openingbalance';

create unique index if not exists ux_spc001_transfers_space_source
    on moneytrack.transfers(space_id, source_type, source_id)
    where space_id is not null
      and source_type is not null
      and source_id is not null;

-- ---------------------------------------------------------------------------
-- 3. Global/template uniqueness remains independent of Space tenancy.
-- Sentinel template user 0 stays GLOBAL_PLATFORM and must not receive space_id.
-- ---------------------------------------------------------------------------

create unique index if not exists ux_spc001_template_accounts_code
    on moneytrack.accounts(code)
    where user_id = 0 and space_id is null;

create unique index if not exists ux_spc001_template_categories_code
    on moneytrack.category_catalog(code)
    where user_id = 0 and space_id is null;

create unique index if not exists ux_spc001_template_products_key
    on moneytrack.product_catalog(product_key)
    where user_id = 0 and space_id is null;

comment on index moneytrack.ux_spc001_accounts_space_code
is 'SPC-001: account code uniqueness belongs to the financial Space, not the actor/user.';
comment on index moneytrack.ux_spc001_categories_space_code
is 'SPC-001: category code uniqueness belongs to the financial Space, not the actor/user.';
comment on index moneytrack.ux_spc001_products_space_key
is 'SPC-001: product identity is Space-local after tenancy cutover.';

commit;
