\set ON_ERROR_STOP on

-- Run only after loading 010/020/025/030 inside the caller's validation transaction.

do $verify$
declare
    v_missing text[] := '{}'::text[];
    v_preset_columns text[];
begin
    if to_regprocedure('moneytrack.api_accounts_explorer_summary_read_model_v2(bigint,bigint[],bigint[],bigint[],date,date,date)') is null then
        v_missing := array_append(v_missing, 'api_accounts_explorer_summary_read_model_v2');
    end if;
    if to_regprocedure('moneytrack.api_transactions_read_model_v2(bigint,bigint,date,date,boolean,bigint[],bigint[],bigint[])') is null then
        v_missing := array_append(v_missing, 'api_transactions_read_model_v2');
    end if;
    if to_regprocedure('moneytrack.account_move_operations_v1(bigint,bigint,bigint)') is null then
        v_missing := array_append(v_missing, 'account_move_operations_v1');
    end if;
    if to_regprocedure('moneytrack.account_archive_v1(bigint,bigint)') is null then
        v_missing := array_append(v_missing, 'account_archive_v1');
    end if;
    if to_regprocedure('moneytrack.account_delete_v1(bigint,bigint)') is null then
        v_missing := array_append(v_missing, 'account_delete_v1');
    end if;
    if to_regprocedure('moneytrack.ux022_account_is_default_v1(bigint,bigint)') is null then
        v_missing := array_append(v_missing, 'ux022_account_is_default_v1');
    end if;
    if to_regprocedure('moneytrack.filter_preset_create_v1(bigint,text,bigint[],bigint[],bigint[])') is null then
        v_missing := array_append(v_missing, 'filter_preset_create_v1');
    end if;

    if cardinality(v_missing) > 0 then
        raise exception 'UX022_FUNCTIONS_MISSING: %', array_to_string(v_missing, ',');
    end if;

    select array_agg(column_name order by ordinal_position)
      into v_preset_columns
      from information_schema.columns
     where table_schema='moneytrack' and table_name='filter_presets';

    if v_preset_columns is null then
        raise exception 'UX022_FILTER_PRESETS_TABLE_MISSING';
    end if;
    if 'date_from' = any(v_preset_columns) or 'date_to' = any(v_preset_columns) then
        raise exception 'UX022_PRESET_PERIOD_COLUMNS_FORBIDDEN';
    end if;

    if position('ACCOUNT_CURRENCY_INCOMPATIBLE' in pg_get_functiondef(
        'moneytrack.account_move_operations_v1(bigint,bigint,bigint)'::regprocedure
    )) = 0 then
        raise exception 'UX022_MOVE_CURRENCY_GUARD_MISSING';
    end if;

    if position('ACCOUNT_HIERARCHY_CYCLE' in pg_get_functiondef(
        'moneytrack.account_move_v1(bigint,bigint,bigint)'::regprocedure
    )) = 0 then
        raise exception 'UX022_CYCLE_GUARD_MISSING';
    end if;

    if position('ACCOUNT_BALANCE_NOT_ZERO' in pg_get_functiondef(
        'moneytrack.account_archive_v1(bigint,bigint)'::regprocedure
    )) = 0 then
        raise exception 'UX022_ARCHIVE_BALANCE_GUARD_MISSING';
    end if;

    if position('ux022_account_is_default_v1' in pg_get_functiondef(
        'moneytrack.account_archive_v1(bigint,bigint)'::regprocedure
    )) = 0 then
        raise exception 'UX022_ARCHIVE_DEFAULT_ACCOUNT_GUARD_MISSING';
    end if;

    if position('ux022_account_is_default_v1' in pg_get_functiondef(
        'moneytrack.account_delete_v1(bigint,bigint)'::regprocedure
    )) = 0 then
        raise exception 'UX022_DELETE_DEFAULT_ACCOUNT_GUARD_MISSING';
    end if;

    if position('jsonb_each_text' in pg_get_functiondef(
        'moneytrack.ux022_account_is_default_v1(bigint,bigint)'::regprocedure
    )) = 0 or position('user_default_accounts' in pg_get_functiondef(
        'moneytrack.ux022_account_is_default_v1(bigint,bigint)'::regprocedure
    )) = 0 then
        raise exception 'UX022_DEFAULT_ACCOUNT_SCHEMA_TOLERANCE_MISSING';
    end if;
end;
$verify$;

-- Existing data must not already contain a hierarchy cycle. Recursive traversal is
-- bounded by the number of accounts so this verifier cannot loop indefinitely.
do $cycles$
declare
    v_account_count bigint;
    v_cycle_count bigint;
begin
    select count(*) into v_account_count from moneytrack.accounts;
    with recursive walk as (
        select a.user_id, a.id as origin_id, a.parent_id, array[a.id]::bigint[] as path, false as cycle, 1 as depth
        from moneytrack.accounts a
        union all
        select w.user_id, w.origin_id, p.parent_id, w.path || p.id,
               p.id = any(w.path) as cycle, w.depth + 1
        from walk w
        join moneytrack.accounts p on p.id=w.parent_id and p.user_id=w.user_id
        where not w.cycle and w.depth <= greatest(v_account_count,1)
    )
    select count(*) into v_cycle_count from walk where cycle;
    if v_cycle_count > 0 then raise exception 'UX022_EXISTING_ACCOUNT_CYCLE count=%', v_cycle_count; end if;
end;
$cycles$;

select 'migration_contract_gate=PASS' as result;
