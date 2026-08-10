\set ON_ERROR_STOP on

-- Fail closed if the live schema contains a direct account-looking column whose
-- lifecycle semantics have not been classified by UX-022. user_settings is a
-- special case: ux022_account_is_default_v1 inspects every account-looking field
-- through to_jsonb(), so it remains schema-tolerant without silently ignoring it.
do $inventory$
declare
    v_unclassified text[];
begin
    select array_agg(format('%I.%I', c.table_name, c.column_name) order by c.table_name, c.column_name)
      into v_unclassified
      from information_schema.columns c
     where c.table_schema = 'moneytrack'
       and (c.column_name = 'account_ids' or c.column_name like '%account_id%')
       and not (
            (c.table_name = 'transactions' and c.column_name = 'account_id')
            or (c.table_name = 'transfers' and c.column_name in ('from_account_id', 'to_account_id'))
            or (c.table_name = 'user_default_accounts' and c.column_name = 'account_id')
            or (c.table_name = 'user_settings' and c.column_name like '%account_id%')
            or (c.table_name = 'filter_presets' and c.column_name = 'account_ids')
       );

    if coalesce(cardinality(v_unclassified), 0) > 0 then
        raise exception 'UX022_UNCLASSIFIED_ACCOUNT_REFERENCES: %', array_to_string(v_unclassified, ',');
    end if;
end;
$inventory$;

select 'account_reference_inventory=PASS' as result;
