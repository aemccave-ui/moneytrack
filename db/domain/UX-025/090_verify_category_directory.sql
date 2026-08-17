-- MoneyTrack — UX-025B — read-only deployed category directory verifier
\set ON_ERROR_STOP on

begin transaction read only;

do $verify$
declare
    v_def text;
begin
    if to_regprocedure('moneytrack.category_directory_space_v1(bigint,bigint)') is null then
        raise exception 'UX025_VERIFY_MISSING category_directory_space_v1';
    end if;
    if to_regprocedure('moneytrack.category_create_space_v1(bigint,bigint,text,text,bigint,integer)') is null then
        raise exception 'UX025_VERIFY_MISSING category_create_space_v1';
    end if;
    if to_regprocedure('moneytrack.category_edit_space_v1(bigint,bigint,bigint,text,text,bigint,integer)') is null then
        raise exception 'UX025_VERIFY_MISSING category_edit_space_v1';
    end if;
    if to_regprocedure('moneytrack.category_reorder_space_v1(bigint,bigint,bigint,text)') is null then
        raise exception 'UX025_VERIFY_MISSING category_reorder_space_v1';
    end if;
    if to_regprocedure('moneytrack.category_reorder_space_v1(bigint,bigint,bigint,integer)') is not null then
        raise exception 'UX025_VERIFY_STALE numeric_reorder_overload';
    end if;
    if to_regprocedure('moneytrack.category_delete_space_v1(bigint,bigint,bigint)') is null then
        raise exception 'UX025_VERIFY_MISSING category_delete_space_v1';
    end if;
    if to_regprocedure('moneytrack.ux025_financial_api_dispatch_v1(bigint,bigint,text,text,jsonb,jsonb)') is null then
        raise exception 'UX025_VERIFY_MISSING ux025_financial_api_dispatch_v1';
    end if;

    select pg_get_functiondef('moneytrack.category_edit_space_v1(bigint,bigint,bigint,text,text,bigint,integer)'::regprocedure)
      into v_def;
    if position('with recursive descendants' in lower(v_def)) = 0
       or position('c.space_id = p_space_id' in lower(v_def)) = 0
       or position('category_parent_cycle' in lower(v_def)) = 0 then
        raise exception 'UX025_VERIFY_EDIT_GUARDS';
    end if;

    select pg_get_functiondef('moneytrack.category_delete_space_v1(bigint,bigint,bigint)'::regprocedure)
      into v_def;
    if position('set is_active = false' in lower(v_def)) = 0
       or position('category_has_active_children' in lower(v_def)) = 0 then
        raise exception 'UX025_VERIFY_ARCHIVE_GUARD';
    end if;

    select pg_get_functiondef('moneytrack.category_reorder_space_v1(bigint,bigint,bigint,text)'::regprocedure)
      into v_def;
    if position('pg_advisory_xact_lock' in lower(v_def)) = 0
       or position('sort_order = v_i * 10' in lower(v_def)) = 0 then
        raise exception 'UX025_VERIFY_REORDER_GUARD';
    end if;

    select pg_get_functiondef('moneytrack.ux025_financial_api_dispatch_v1(bigint,bigint,text,text,jsonb,jsonb)'::regprocedure)
      into v_def;
    if position('spc001_financial_api_dispatch_v1' in lower(v_def)) = 0
       or position('api/v1/categories' in lower(v_def)) = 0 then
        raise exception 'UX025_VERIFY_DISPATCH_DELEGATION';
    end if;
end;
$verify$;

select 'UX025_CATEGORY_DIRECTORY_OBJECTS=PASS' as marker;
select 'UX025_DB_POST_VERIFY_READONLY=PASS' as marker;
rollback;
