-- MoneyTrack — SPC-001D3 — live post-migration structural verifier
-- READ ONLY. Safe to run on the migrated live database: no fixture rows,
-- sequences, workflows or runtime state are mutated.

begin transaction read only;

\pset format unaligned
\pset tuples_only on

\echo SPC001_LIVE_POST_MIGRATION_VERIFY=BEGIN

do $verify$
declare
    v_errors text[] := '{}'::text[];
    v_count bigint;
begin
    -- Required canonical objects.
    if to_regprocedure('moneytrack.assert_space_member_v1(bigint,bigint)') is null then
        v_errors := array_append(v_errors,'assert_space_member_missing');
    end if;
    if to_regprocedure('moneytrack.space_create_v1(bigint,text)') is null then
        v_errors := array_append(v_errors,'space_create_missing');
    end if;
    if to_regprocedure('moneytrack.capture_create_projection_v1(bigint,bigint,text,text,bigint,text,numeric,text,text,timestamp with time zone,bigint,jsonb)') is null then
        v_errors := array_append(v_errors,'capture_create_projection_missing');
    end if;
    if to_regclass('moneytrack.space_financial_settings') is null then
        v_errors := array_append(v_errors,'space_financial_settings_missing');
    end if;
    if to_regclass('moneytrack.space_default_accounts') is null then
        v_errors := array_append(v_errors,'space_default_accounts_missing');
    end if;
    if to_regclass('moneytrack.capture_events') is null then
        v_errors := array_append(v_errors,'capture_events_missing');
    end if;

    -- Every non-template legacy finance row is now Space-owned.
    select count(*) into v_count from moneytrack.accounts where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'accounts_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transfers where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfers_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.receipts where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipts_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'categories_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'products_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.budget_rules where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'budgets_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.filter_presets where user_id<>0 and space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_presets_missing_space='||v_count); end if;

    -- Platform/template catalog remains global.
    select count(*) into v_count from moneytrack.accounts where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_accounts_space_leak='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_categories_space_leak='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog where user_id=0 and space_id is not null;
    if v_count<>0 then v_errors:=array_append(v_errors,'template_products_space_leak='||v_count); end if;

    -- Exactly one active Personal Space per non-template user, owner membership only.
    select count(*) into v_count
    from moneytrack.app_users u
    where u.id<>0
      and 1<>(
          select count(*)
          from moneytrack.workspaces w
          join moneytrack.workspace_members wm
            on wm.workspace_id=w.id
           and wm.user_id=u.id
           and coalesce(wm.is_active,true)=true
          where w.owner_user_id=u.id
            and w.workspace_type='personal'
            and coalesce(w.is_active,true)=true
      );
    if v_count<>0 then v_errors:=array_append(v_errors,'personal_space_cardinality='||v_count); end if;

    select count(*) into v_count
    from moneytrack.workspaces w
    join moneytrack.workspace_members wm on wm.workspace_id=w.id
    where w.workspace_type='personal'
      and coalesce(w.is_active,true)=true
      and coalesce(wm.is_active,true)=true
      and wm.user_id is distinct from w.owner_user_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'personal_space_foreign_members='||v_count); end if;

    -- Same-Space relational invariants.
    select count(*) into v_count
    from moneytrack.accounts a join moneytrack.accounts p on p.id=a.parent_id
    where a.parent_id is not null and a.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'account_parent_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.category_catalog c join moneytrack.category_catalog p on p.id=c.parent_id
    where c.parent_id is not null and c.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'category_parent_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
    where t.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.transactions t join moneytrack.category_catalog c on c.id=t.category_id
    where t.category_id is not null and t.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.transfers t
    join moneytrack.accounts a1 on a1.id=t.from_account_id
    join moneytrack.accounts a2 on a2.id=t.to_account_id
    where t.space_id is distinct from a1.space_id or t.space_id is distinct from a2.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfer_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.receipts r join moneytrack.transactions t on t.id=r.transaction_id
    where r.transaction_id is not null and r.space_id is distinct from t.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_transaction_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.receipt_items ri
    join moneytrack.receipts r on r.id=ri.receipt_id
    join moneytrack.category_catalog c on c.id=ri.category_id
    where ri.category_id is not null and r.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.receipt_items ri
    join moneytrack.receipts r on r.id=ri.receipt_id
    join moneytrack.product_catalog p on p.id=ri.product_id
    where ri.product_id is not null and r.space_id is distinct from p.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipt_item_product_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.product_catalog p join moneytrack.category_catalog c on c.id=p.category_id
    where p.category_id is not null and p.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'product_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.budget_rules b join moneytrack.category_catalog c on c.id=b.category_id
    where b.category_id is not null and b.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'budget_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.space_default_accounts d join moneytrack.accounts a on a.id=d.account_id
    where d.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'space_default_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.space_financial_settings s
    join moneytrack.accounts a
      on a.id in (s.default_expense_account_id,s.default_income_account_id)
    where a.space_id is distinct from s.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'space_financial_setting_cross_space='||v_count); end if;

    -- User+Space filter preferences may only reference finance ids in that Space.
    select count(*) into v_count
    from moneytrack.filter_presets fp
    cross join lateral unnest(coalesce(fp.account_ids,'{}'::bigint[])) x(id)
    where not exists (
        select 1 from moneytrack.accounts a where a.id=x.id and a.space_id=fp.space_id
    );
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.filter_presets fp
    cross join lateral unnest(
        coalesce(fp.income_category_ids,'{}'::bigint[])
        || coalesce(fp.expense_category_ids,'{}'::bigint[])
    ) x(id)
    where not exists (
        select 1 from moneytrack.category_catalog c where c.id=x.id and c.space_id=fp.space_id
    );
    if v_count<>0 then v_errors:=array_append(v_errors,'filter_category_cross_space='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_LIVE_POST_MIGRATION_VERIFY_FAILED: %',array_to_string(v_errors,';');
    end if;
end;
$verify$;

select 'POST_MIGRATION_COUNTS|users='||(select count(*) from moneytrack.app_users)
    ||'|spaces='||(select count(*) from moneytrack.workspaces)
    ||'|members='||(select count(*) from moneytrack.workspace_members)
    ||'|accounts='||(select count(*) from moneytrack.accounts)
    ||'|transactions='||(select count(*) from moneytrack.transactions)
    ||'|transfers='||(select count(*) from moneytrack.transfers)
    ||'|receipts='||(select count(*) from moneytrack.receipts)
    ||'|categories='||(select count(*) from moneytrack.category_catalog)
    ||'|products='||(select count(*) from moneytrack.product_catalog)
    ||'|budgets='||(select count(*) from moneytrack.budget_rules);

\echo SPC001_LIVE_POST_MIGRATION_VERIFY=PASS
\echo SPC001_LIVE_POST_MIGRATION_VERIFY=END
rollback;
