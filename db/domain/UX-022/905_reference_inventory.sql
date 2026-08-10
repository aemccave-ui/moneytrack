\set ON_ERROR_STOP on

-- Fail closed if the live schema contains a direct account-looking column whose
-- lifecycle semantics have not been classified by UX-022.
do $inventory$
declare
    v_unclassified text[];
begin
    select array_agg(format('%I.%I', c.table_name, c.column_name) order by c.table_name, c.column_name)
      into v_unclassified
      from information_schema.columns c
     where c.table_schema = 'moneytrack'
       and (c.column_name = 'account_ids' or c.column_name like '%account_id%')
       and (c.table_name, c.column_name) not in (
            ('transactions', 'account_id'),
            ('transfers', 'from_account_id'),
            ('transfers', 'to_account_id'),
            ('user_default_accounts', 'account_id'),
            ('user_settings', 'default_expense_account_id'),
            ('user_settings', 'default_income_account_id'),
            ('filter_presets', 'account_ids')
       );

    if coalesce(cardinality(v_unclassified), 0) > 0 then
        raise exception 'UX022_UNCLASSIFIED_ACCOUNT_REFERENCES: %', array_to_string(v_unclassified, ',');
    end if;
end;
$inventory$;

select 'account_reference_inventory=PASS' as result;
