-- MoneyTrack — SPC-001A — Space uniqueness + bootstrap verifier
--
-- Run only after 010 + 012 + 013 + 014 + 020 + 021 in a controlled dry-run DB.
-- Synthetic state is always rolled back.

begin;

do $space_uniqueness_fixture$
declare
    v_currency text;
    v_language text;
    v_account_type text;
    v_actor bigint;
    v_s1 bigint;
    v_s2 bigint;
    v_a1 bigint;
    v_a2 bigint;
    v_c1 bigint;
    v_c2 bigint;
    v_p1 bigint;
    v_p2 bigint;
    v_t1 bigint;
    v_t2 bigint;
begin
    select coalesce(u.default_currency,'EUR'), coalesce(u.language_code,'en')
      into v_currency, v_language
      from moneytrack.app_users u
     where u.id = 0;

    select a.account_type
      into v_account_type
      from moneytrack.accounts a
     where a.user_id = 0
     order by a.id
     limit 1;

    if v_currency is null or v_account_type is null then
        raise exception 'SPC001_TEMPLATE_FIXTURE_MISSING';
    end if;

    insert into moneytrack.app_users(
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        -910000001, 'spc_multi', 'SPC Multi', v_language, v_currency
    ) returning id into v_actor;

    insert into moneytrack.workspaces(name,workspace_type,owner_user_id,is_active,created_at)
    values ('SPC U1','personal',v_actor,true,now()) returning id into v_s1;
    insert into moneytrack.workspaces(name,workspace_type,owner_user_id,is_active,created_at)
    values ('SPC U2','personal',v_actor,true,now()) returning id into v_s2;

    insert into moneytrack.workspace_members(workspace_id,user_id,role,is_active,created_at)
    values
      (v_s1,v_actor,'owner',true,now()),
      (v_s2,v_actor,'owner',true,now());

    insert into moneytrack.space_financial_settings(space_id,base_currency,report_currency)
    values (v_s1,v_currency,v_currency),(v_s2,v_currency,v_currency);

    -- Same actor + same account code MUST coexist in independent Spaces.
    insert into moneytrack.accounts(
        user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,
        created_by_user_id,updated_by_user_id
    ) values (
        v_actor,v_s1,'same_cash','Same Cash',v_account_type,v_currency,true,now(),10,null,v_actor,v_actor
    ) returning id into v_a1;

    insert into moneytrack.accounts(
        user_id,space_id,code,name,account_type,currency_code,is_active,created_at,sort_order,parent_id,
        created_by_user_id,updated_by_user_id
    ) values (
        v_actor,v_s2,'same_cash','Same Cash',v_account_type,v_currency,true,now(),10,null,v_actor,v_actor
    ) returning id into v_a2;

    if v_a1 = v_a2 then raise exception 'SPC001_ACCOUNT_SPACE_UNIQUENESS_FAILED'; end if;

    -- Same actor + same category code MUST coexist in independent Spaces.
    insert into moneytrack.category_catalog(
        user_id,space_id,code,parent_id,is_active,sort_order,created_at,
        created_by_user_id,updated_by_user_id
    ) values (v_actor,v_s1,'same_category',null,true,10,now(),v_actor,v_actor)
    returning id into v_c1;

    insert into moneytrack.category_catalog(
        user_id,space_id,code,parent_id,is_active,sort_order,created_at,
        created_by_user_id,updated_by_user_id
    ) values (v_actor,v_s2,'same_category',null,true,10,now(),v_actor,v_actor)
    returning id into v_c2;

    if v_c1 = v_c2 then raise exception 'SPC001_CATEGORY_SPACE_UNIQUENESS_FAILED'; end if;

    -- Same actor + same product key MUST coexist in independent Spaces.
    insert into moneytrack.product_catalog(
        user_id,space_id,product_key,original_name,category_id,is_active,created_at,
        created_by_user_id,updated_by_user_id
    ) values (v_actor,v_s1,'same_product','Same Product',v_c1,true,now(),v_actor,v_actor)
    returning id into v_p1;

    insert into moneytrack.product_catalog(
        user_id,space_id,product_key,original_name,category_id,is_active,created_at,
        created_by_user_id,updated_by_user_id
    ) values (v_actor,v_s2,'same_product','Same Product',v_c2,true,now(),v_actor,v_actor)
    returning id into v_p2;

    if v_p1 = v_p2 then raise exception 'SPC001_PRODUCT_SPACE_UNIQUENESS_FAILED'; end if;

    -- Same source identity may be projected independently into two Spaces.
    select t.id into v_t1
      from moneytrack.finance_create_transaction_space_v1(
          v_actor,v_s1,v_a1,'expense',1,v_currency,'projection one',now(),'text',777001,v_c1
      ) t;
    select t.id into v_t2
      from moneytrack.finance_create_transaction_space_v1(
          v_actor,v_s2,v_a2,'expense',1,v_currency,'projection two',now(),'text',777001,v_c2
      ) t;

    if v_t1 is null or v_t2 is null or v_t1 = v_t2 then
        raise exception 'SPC001_SOURCE_ID_SPACE_UNIQUENESS_FAILED';
    end if;

    raise notice 'SPACE_ACCOUNT_UNIQUENESS=PASS';
    raise notice 'SPACE_CATEGORY_UNIQUENESS=PASS';
    raise notice 'SPACE_PRODUCT_UNIQUENESS=PASS';
    raise notice 'SPACE_SOURCE_IDEMPOTENCY=PASS';
end;
$space_uniqueness_fixture$;


do $new_user_bootstrap_fixture$
declare
    r record;
    v_missing bigint;
    v_foreign bigint;
begin
    select * into r
      from moneytrack.spc001_user_bootstrap_v1(
          -910000002,'spc_bootstrap','SPC Bootstrap','en'
      );

    if r.user_id is null or r.space_id is null then
        raise exception 'SPC001_NEW_USER_BOOTSTRAP_MISSING_IDENTITY_OR_SPACE';
    end if;

    perform moneytrack.assert_space_member_v1(r.user_id,r.space_id);

    select count(*) into v_missing
      from moneytrack.accounts a
     where a.user_id=r.user_id and a.space_id is null;
    if v_missing<>0 then
        raise exception 'SPC001_BOOTSTRAP_ACCOUNT_WITHOUT_SPACE: %',v_missing;
    end if;

    select count(*) into v_missing
      from moneytrack.category_catalog c
     where c.user_id=r.user_id and c.space_id is null;
    if v_missing<>0 then
        raise exception 'SPC001_BOOTSTRAP_CATEGORY_WITHOUT_SPACE: %',v_missing;
    end if;

    if not exists (
        select 1 from moneytrack.space_financial_settings s where s.space_id=r.space_id
    ) then
        raise exception 'SPC001_BOOTSTRAP_SPACE_SETTINGS_MISSING';
    end if;

    -- A guessed unrelated Space cannot be used as the bootstrap actor context.
    select w.id into v_foreign
      from moneytrack.workspaces w
     where w.id<>r.space_id
       and not exists (
           select 1 from moneytrack.workspace_members wm
           where wm.workspace_id=w.id and wm.user_id=r.user_id and coalesce(wm.is_active,true)=true
       )
     order by w.id
     limit 1;

    if v_foreign is not null then
        begin
            perform moneytrack.spc001_bootstrap_space_finance_v1(r.user_id,v_foreign);
            raise exception 'SPC001_BOOTSTRAP_FOREIGN_SPACE_NOT_REJECTED';
        exception
            when others then
                if sqlerrm='SPC001_BOOTSTRAP_FOREIGN_SPACE_NOT_REJECTED' then raise; end if;
                if sqlerrm not like '%SPACE_NOT_FOUND_OR_NOT_MEMBER%' then raise; end if;
        end;
    end if;

    raise notice 'NEW_USER_SPACE_BOOTSTRAP=PASS';
end;
$new_user_bootstrap_fixture$;

rollback;
