-- MoneyTrack — SPC-001D — deterministic runtime table fingerprint
-- READ ONLY. Produces an order-independent digest for every ordinary table in
-- the moneytrack schema. Used before/after isolated rollback rehearsal and on
-- the live DB to prove that the rehearsal itself did not alter live table data.

\set ON_ERROR_STOP on
begin transaction read only;
\pset tuples_only on
\pset format unaligned

select 'SPC001_TABLE_FINGERPRINT=BEGIN';

select format(
    'select %L || ''|rows='' || count(*)::text || ''|digest='' || md5(coalesce(string_agg(md5(to_jsonb(t)::text), '''' order by md5(to_jsonb(t)::text)), '''')) from %I.%I t;',
    'TABLE_FINGERPRINT|table=' || tablename,
    schemaname,
    tablename
)
from pg_tables
where schemaname = 'moneytrack'
order by tablename
\gexec

select 'SPC001_TABLE_FINGERPRINT=END';
rollback;
