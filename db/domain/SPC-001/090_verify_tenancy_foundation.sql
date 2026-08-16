-- MoneyTrack — SPC-001A — tenancy foundation verifier
--
-- Run only after 010 + 020 + 021 in a controlled migration/dry-run database.
-- The synthetic tenant-isolation fixture is enclosed in one transaction and
-- always rolled back. No fixture state survives.

begin;

-- ---------------------------------------------------------------------------
-- Structural migration reconciliation.
-- ---------------------------------------------------------------------------

do $reconcile$
declare
    v_count bigint;
    v_errors text[] := '{}'::text[];
begin
    if to_regprocedure('moneytrack.assert_space_member_v1(bigint,bigint)') is null then
        v_errors := array_append(v_errors,'assert_space_member_missing');
    end if;
    if to_regprocedure('moneytrack.finance_create_transaction_space_v1(bigint,bigint,bigint,text,numeric,text,text,timestamp with time zone,text,bigint,bigint)') is null then
        v_errors := array_append(v_errors,'space_transaction_write_missing');
    end if;

    select count(*) into v_count from moneytrack.accounts a where a.user_id<>0 and a.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'accounts_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transactions t where t.user_id<>0 and t.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transactions_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.transfers t where t.user_id<>0 and t.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfers_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.receipts r where r.user_id<>0 and r.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'receipts_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.category_catalog c where c.user_id<>0 and c.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'categories_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.product_catalog p where p.user_id<>0 and p.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'products_missing_space='||v_count); end if;
    select count(*) into v_count from moneytrack.budget_rules b where b.user_id<>0 and b.space_id is null;
    if v_count<>0 then v_errors:=array_append(v_errors,'budgets_missing_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.transactions t join moneytrack.accounts a on a.id=t.account_id
    where t.space_id is distinct from a.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_account_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.transactions t join moneytrack.category_catalog c on c.id=t.category_id
    where t.category_id is not null and t.space_id is distinct from c.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transaction_category_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.transfers tr
    join moneytrack.accounts a1 on a1.id=tr.from_account_id
    join moneytrack.accounts a2 on a2.id=tr.to_account_id
    where tr.space_id is distinct from a1.space_id or tr.space_id is distinct from a2.space_id;
    if v_count<>0 then v_errors:=array_append(v_errors,'transfer_cross_space='||v_count); end if;

    select count(*) into v_count
    from moneytrack.app_users u
    where u.id<>0 and not exists (
        select 1 from moneytrack.workspaces w
        join moneytrack.workspace_members wm on wm.workspace_id=w.id and wm.user_id=u.id and coalesce(wm.is_active,true)=true
        where w.owner_user_id=u.id and w.workspace_type='personal' and coalesce(w.is_active,true)=true
    );
    if v_count<>0 then v_errors:=array_append(v_errors,'personal_owner_membership_missing='||v_count); end if;

    if cardinality(v_errors)>0 then
        raise exception 'SPC001_RECONCILIATION_VERIFY_FAILED: %',array_to_string(v_errors,';');
    end if;
end;
$reconcile$;

-- ---------------------------------------------------------------------------
-- Synthetic A/B/C tenant fixture.
-- P = A personal only
-- F = B-owned Space with A+B (A is explicitly a non-owner financial member)
-- B = C-owned Space with B+C
-- This realizes the required visibility graph while independently proving that
-- owner status is not needed for financial CRUD.
-- ---------------------------------------------------------------------------

do $tenant_fixture$
declare
    v_lang text;
    v_currency text;
    v_account_type text;
    v_a bigint;
    v_b bigint;
    v_c bigint;
    v_p bigint;
    v_f bigint;
    v_bspace bigint;
    v_pa bigint;
    v_fa bigint;
    v_ba bigint;
    v_tx moneytrack.transactions%rowtype;
    v_updated moneytrack.transactions%rowtype;
    v_rejected boolean;
begin
    select coalesce(u.language_code,'en'),coalesce(u.default_currency,'EUR')
      into v_lang,v_currency from moneytrack.app_users u where u.id=0;
    if v_currency is null then raise exception 'SPC001_FIXTURE_TEMPLATE_USER_MISSING'; end if;

    select a.account_type into v_account_type
    from moneytrack.accounts a where a.user_id=0 order by a.id limit 1;
    if v_account_type is null then raise exception 'SPC001_FIXTURE_TEMPLATE_ACCOUNT_MISSING'; end if;

    insert into moneytrack.app_users(telegram_user_id,username,first_name,language_code,default_currency)
    values (-900000001,'spc_a','SPC A',v_lang,v_currency) returning id into v_a;
    insert into moneytrack.app_users(telegram_user_id,username,first_name,language_code,default_currency)
    values (-900000002,'spc_b','SPC B',v_lang,v_currency) returning id into v_b;
    insert into moneytrack.app_users(telegram_user_id,username,first_name,language_code,default_currency)
    values (-900000003,'spc_c','SPC C',v_lang,v_currency) returning id into v_c;

    insert into moneytrack.workspaces(name,workspace_type,owner_user_id,is_active,created_at)
    values ('SPC P','personal',v_a,true,now()) returning id into v_p;
    insert into moneytrack.workspaces(name,workspace_type,owner_user_id,is_active,created_at)
    values ('SPC F','personal',v_b,true,now()) returning id into v_f;
    insert into moneytrack.workspaces(name,workspace_type,owner_user_id,is_active,created_at)
    values ('SPC B','personal',v_c,true,now()) returning id into v_bspace;

    insert into moneytrack.workspace_members(workspace_id,user_id,role,is_active,created_at)
    values
      (v_p,v_a,'owner',true,now()),
      (v_f,v_b,'owner',true,now()),
      (v_f,v_a,'member',true,now()),
      (v_bspace,v_c,'owner',true,now()),
      (v_bspace,v_b,'member',true,now());

    insert into moneytrack.space_financial_settings(space_id,base_currency,report_currency)
    values (v_p,v_currency,v_currency),(v_f,v_currency,v_currency),(v_bspace,v_currency,v_currency);

    insert into moneytrack.accounts(
        user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,
        created_by_user_id,updated_by_user_id
    ) values (v_a,v_p,'spc_p_cash','P cash',v_account_type,v_currency,true,now(),10,null,v_a,v_a)
    returning id into v_pa;
    insert into moneytrack.accounts(
        user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,
        created_by_user_id,updated_by_user_id
    ) values (v_a,v_f,'spc_f_cash','F cash',v_account_type,v_currency,true,now(),10,null,v_a,v_a)
    returning id into v_fa;
    insert into moneytrack.accounts(
        user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,
        created_by_user_id,updated_by_user_id
    ) values (v_b,v_bspace,'spc_b_cash','B cash',v_account_type,v_currency,true,now(),10,null,v_b,v_b)
    returning id into v_ba;

    -- A is not owner of F, but active membership must be sufficient.
    v_tx := moneytrack.finance_create_transaction_space_v1(
        v_a,v_f,v_fa,'expense',10,v_currency,'shared fixture',now(),null,null,null
    );
    if v_tx.created_by_user_id is distinct from v_a then
        raise exception 'SPC001_AUTHORSHIP_CREATE_FAILED';
    end if;

    -- Owner B can read/edit, but editing must not overwrite A's original author.
    perform moneytrack.finance_transactions_space_read_model_v1(v_b,v_f,current_date-1,current_date+1);
    v_updated := moneytrack.finance_update_transaction_space_v1(
        v_b,v_f,v_tx.id,v_fa,'expense',11,v_currency,'edited by B',v_tx.transaction_date,null
    );
    if v_updated.created_by_user_id is distinct from v_a or v_updated.updated_by_user_id is distinct from v_b then
        raise exception 'SPC001_AUTHORSHIP_EDIT_FAILED';
    end if;

    -- C is not a member of F: guessed Space id must fail closed.
    v_rejected:=false;
    begin
        perform moneytrack.finance_transactions_space_read_model_v1(v_c,v_f,current_date-1,current_date+1);
    exception when others then
        if sqlerrm like '%SPACE_NOT_FOUND_OR_NOT_MEMBER%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_FOREIGN_SPACE_READ_NOT_REJECTED'; end if;

    -- A is member of F but P's account id is foreign to F: fail closed.
    v_rejected:=false;
    begin
        perform moneytrack.finance_create_transaction_space_v1(
            v_a,v_f,v_pa,'expense',1,v_currency,'foreign account',now(),null,null,null
        );
    exception when others then
        if sqlerrm like '%ACCOUNT_NOT_FOUND_IN_SPACE%' or sqlerrm like '%CROSS_SPACE%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_FOREIGN_ACCOUNT_WRITE_NOT_REJECTED'; end if;

    -- Membership removal must invalidate the next request immediately.
    update moneytrack.workspace_members wm set is_active=false
    where wm.workspace_id=v_f and wm.user_id=v_a;
    v_rejected:=false;
    begin
        perform moneytrack.finance_transactions_space_read_model_v1(v_a,v_f,current_date-1,current_date+1);
    exception when others then
        if sqlerrm like '%SPACE_NOT_FOUND_OR_NOT_MEMBER%' then v_rejected:=true; else raise; end if;
    end;
    if not v_rejected then raise exception 'SPC001_MEMBER_REMOVAL_NOT_IMMEDIATE'; end if;

    raise notice 'TENANT_ISOLATION=PASS';
    raise notice 'SHARED_FINANCIAL_RIGHTS=PASS';
    raise notice 'AUTHORSHIP=PASS';
    raise notice 'FOREIGN_SPACE_FAIL_CLOSED=PASS';
    raise notice 'FOREIGN_ACCOUNT_FAIL_CLOSED=PASS';
    raise notice 'MEMBER_REMOVAL_IMMEDIATE=PASS';
end;
$tenant_fixture$;

rollback;
