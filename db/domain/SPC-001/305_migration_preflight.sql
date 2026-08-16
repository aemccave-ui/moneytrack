-- MoneyTrack — SPC-001D — live DB migration preflight
--
-- READ ONLY. Run against the current MoneyTrack PostgreSQL before any SPC-001
-- database mutation. It rejects legacy states that cannot be mapped
-- deterministically to one Personal Space per user.

\set ON_ERROR_STOP on
begin transaction read only;

\pset tuples_only on
\pset format unaligned

do $preflight$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
    v_space_columns bigint;
    v_name text;
begin
    foreach v_name in array array[
        'app_users','workspaces','workspace_members','user_settings',
        'accounts','transactions','transfers','receipts','receipt_items',
        'category_catalog','product_catalog','budget_rules','filter_presets',
        'user_default_accounts','currencies'
    ] loop
        if to_regclass('moneytrack.' || v_name) is null then
            v_errors:=array_append(v_errors,'missing_table='||v_name);
        end if;
    end loop;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_DB_PREFLIGHT_FAILED: %',array_to_string(v_errors,';');
    end if;

    if not exists(select 1 from moneytrack.app_users where id=0) then
        v_errors:=array_append(v_errors,'template_user_0_missing');
    end if;
    if not exists(select 1 from moneytrack.accounts where user_id=0) then
        v_errors:=array_append(v_errors,'template_accounts_missing');
    end if;
    if not exists(select 1 from moneytrack.category_catalog where user_id=0) then
        v_errors:=array_append(v_errors,'template_categories_missing');
    end if;

    -- No partial SPC physical tenancy state is accepted for the first controlled
    -- migration. This prevents silently reconciling an unknown previous apply.
    select count(*) into v_space_columns
      from information_schema.columns
     where table_schema='moneytrack'
       and column_name='space_id'
       and table_name in (
           'accounts','transactions','transfers','receipts',
           'category_catalog','product_catalog','budget_rules','filter_presets'
       );
    if v_space_columns<>0 then
        v_errors:=array_append(v_errors,'spc_space_columns_already_present='||v_space_columns);
    end if;
    if to_regprocedure('moneytrack.assert_space_member_v1(bigint,bigint)') is not null then
        v_errors:=array_append(v_errors,'spc_runtime_function_already_present');
    end if;

    -- One owner may have zero or one active Personal Space before migration.
    select count(*) into v_count
      from (
        select w.owner_user_id
          from moneytrack.workspaces w
         where w.workspace_type='personal'
           and coalesce(w.is_active,true)=true
           and w.owner_user_id is not null
         group by w.owner_user_id
        having count(*)>1
      ) x;
    if v_count<>0 then v_errors:=array_append(v_errors,'multiple_active_personal_space_owners='||v_count); end if;

    -- A pre-existing Personal Space must not expose the owner's future migrated
    -- finance to another active member.
    select count(*) into v_count
      from moneytrack.workspaces w
      join moneytrack.workspace_members wm on wm.workspace_id=w.id
     where w.workspace_type='personal'
       and coalesce(w.is_active,true)=true
       and coalesce(wm.is_active,true)=true
       and wm.user_id is distinct from w.owner_user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'personal_space_foreign_members='||v_count); end if;

    -- Legacy finance rows need an owning actor in order to map deterministically.
    select count(*) into v_count from moneytrack.accounts where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'accounts_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.transfers where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfers_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.receipts where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipts_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'categories_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'products_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.budget_rules where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'budgets_null_user='||v_count); end if;
    select count(*) into v_count from moneytrack.filter_presets where user_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_presets_null_user='||v_count); end if;

    -- Every legacy financial reference must stay within the same user. After the
    -- migration this becomes the same-Space relational invariant.
    select count(*) into v_count
      from moneytrack.accounts a
      join moneytrack.accounts p on p.id=a.parent_id
     where a.parent_id is not null and p.user_id is distinct from a.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'account_parent_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions t
      join moneytrack.accounts a on a.id=t.account_id
     where a.user_id is distinct from t.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transactions t
      join moneytrack.category_catalog c on c.id=t.category_id
     where t.category_id is not null and c.user_id is distinct from t.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_category_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.transfers t
      join moneytrack.accounts a1 on a1.id=t.from_account_id
      join moneytrack.accounts a2 on a2.id=t.to_account_id
     where a1.user_id is distinct from t.user_id or a2.user_id is distinct from t.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfer_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipts r
      join moneytrack.transactions t on t.id=r.transaction_id
     where t.user_id is distinct from r.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_transaction_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.category_catalog c on c.id=ri.category_id
     where ri.category_id is not null and c.user_id is distinct from r.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_category_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.receipt_items ri
      join moneytrack.receipts r on r.id=ri.receipt_id
      join moneytrack.product_catalog p on p.id=ri.product_id
     where ri.product_id is not null and p.user_id is distinct from r.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_product_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.product_catalog p
      join moneytrack.category_catalog c on c.id=p.category_id
     where p.category_id is not null and c.user_id is distinct from p.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'product_category_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.budget_rules b
      join moneytrack.category_catalog c on c.id=b.category_id
     where b.category_id is not null and c.user_id is distinct from b.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'budget_category_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.user_default_accounts d
      join moneytrack.accounts a on a.id=d.account_id
     where a.user_id is distinct from d.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.user_settings s
      join moneytrack.accounts a on a.id=s.default_expense_account_id
     where s.default_expense_account_id is not null and a.user_id is distinct from s.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_expense_account_cross_user='||v_count); end if;

    select count(*) into v_count
      from moneytrack.user_settings s
      join moneytrack.accounts a on a.id=s.default_income_account_id
     where s.default_income_account_id is not null and a.user_id is distinct from s.user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'default_income_account_cross_user='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_DB_PREFLIGHT_FAILED: %',array_to_string(v_errors,';');
    end if;
end;
$preflight$;

select 'SPC001_DB_PREFLIGHT=PASS';
select 'app_users='||count(*) from moneytrack.app_users where id<>0;
select 'accounts='||count(*) from moneytrack.accounts;
select 'transactions='||count(*)||' amount_original='||coalesce(sum(amount_original),0)||' amount_base='||coalesce(sum(amount_base),0) from moneytrack.transactions;
select 'transfers='||count(*)||' from_amount='||coalesce(sum(from_amount),0)||' to_amount='||coalesce(sum(to_amount),0) from moneytrack.transfers;
select 'receipts='||count(*)||' total_amount='||coalesce(sum(total_amount),0) from moneytrack.receipts;
select 'receipt_items='||count(*)||' amount='||coalesce(sum(amount),0) from moneytrack.receipt_items;
select 'categories='||count(*) from moneytrack.category_catalog;
select 'products='||count(*) from moneytrack.product_catalog;
select 'budgets='||count(*) from moneytrack.budget_rules;
select 'filter_presets='||count(*) from moneytrack.filter_presets;
select 'active_personal_spaces_existing='||count(*) from moneytrack.workspaces where workspace_type='personal' and coalesce(is_active,true)=true;

rollback;
