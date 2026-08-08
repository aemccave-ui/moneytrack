-- MoneyTrack — BE-DOM-001 — rollback-safe verification for user_delete_me_v1
--
-- Creates disposable synthetic users and a representative user aggregate,
-- exercises invalid + valid confirmation paths, proves cross-user workspace
-- cleanup, then rolls the whole verification transaction back.

begin;

DO $verify$
declare
    v_user_id bigint;
    v_other_user_id bigint;
    v_currency text;
    v_account_type text;
    v_account_1 bigint;
    v_account_2 bigint;
    v_workspace bigint;
    v_other_workspace bigint;
    v_category bigint;
    v_product bigint;
    v_tx_id bigint;
    v_transfer_id bigint;
    v_receipt bigint;
    v_result record;
begin
    -- Reuse a known-good currency/account type from production reference data,
    -- while all user rows created below remain synthetic and rollback-scoped.
    select upper(a.currency_code), a.account_type
      into v_currency, v_account_type
      from moneytrack.accounts a
     where coalesce(a.is_active, true) = true
     order by a.id
     limit 1;

    if v_currency is null or v_account_type is null then
        raise exception 'VERIFY_REQUIRES_REFERENCE_ACCOUNT_FIXTURE';
    end if;

    insert into moneytrack.app_users(
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        900000000001, 'be_dom_erase_target', 'Erase Target', 'en', v_currency
    ) returning id into v_user_id;

    insert into moneytrack.app_users(
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        900000000002, 'be_dom_erase_other', 'Erase Other', 'en', v_currency
    ) returning id into v_other_user_id;

    insert into moneytrack.workspaces(name, workspace_type, owner_user_id, is_active)
    values ('BE-DOM erasure owned workspace', 'personal', v_user_id, true)
    returning id into v_workspace;

    insert into moneytrack.workspaces(name, workspace_type, owner_user_id, is_active)
    values ('BE-DOM erasure foreign workspace', 'personal', v_other_user_id, true)
    returning id into v_other_workspace;

    insert into moneytrack.workspace_members(workspace_id,user_id,role,is_active)
    values
        (v_workspace, v_user_id, 'owner', true),
        (v_workspace, v_other_user_id, 'member', true),
        (v_other_workspace, v_other_user_id, 'owner', true),
        (v_other_workspace, v_user_id, 'member', true);

    insert into moneytrack.user_settings(
        user_id, base_currency, report_currency, language_code, current_workspace_id
    ) values
        (v_user_id, v_currency, v_currency, 'en', v_workspace),
        (v_other_user_id, v_currency, v_currency, 'en', v_workspace);

    insert into moneytrack.accounts(
        user_id, code, name, account_type, currency_code, is_active
    ) values (
        v_user_id,
        'be_dom_erase_a1_' || v_user_id,
        'BE-DOM Erase A1',
        v_account_type,
        v_currency,
        true
    ) returning id into v_account_1;

    insert into moneytrack.accounts(
        user_id, code, name, account_type, currency_code, is_active
    ) values (
        v_user_id,
        'be_dom_erase_a2_' || v_user_id,
        'BE-DOM Erase A2',
        v_account_type,
        v_currency,
        true
    ) returning id into v_account_2;

    insert into moneytrack.user_default_accounts(user_id,currency_code,account_id)
    values (v_user_id,v_currency,v_account_1);

    insert into moneytrack.user_currencies(user_id,currency_code,is_base,is_report,is_active)
    values (v_user_id,v_currency,true,true,true);

    insert into moneytrack.category_catalog(user_id,code,is_active,sort_order)
    values (v_user_id,'be_dom_erase_category_' || v_user_id,true,100)
    returning id into v_category;

    insert into moneytrack.product_catalog(
        user_id,product_key,original_name,category_id,is_active
    ) values (
        v_user_id,
        'be_dom_erase_product_' || v_user_id,
        'BE-DOM erase product',
        v_category,
        true
    ) returning id into v_product;

    insert into moneytrack.budget_rules(
        user_id,category_id,name,amount,currency_code,
        recurrence_type,recurrence_interval,valid_from,is_active
    ) values (
        v_user_id,v_category,'BE-DOM erase budget',1,v_currency,
        'once',1,current_date,true
    );

    select id into v_tx_id
      from moneytrack.finance_create_transaction_v1(
          v_user_id,
          v_account_1,
          'expense',
          1.23,
          v_currency,
          'BE-DOM erasure verification',
          now(),
          'be_dom_001_erasure_verify',
          940001,
          v_category
      );

    select id into v_transfer_id
      from moneytrack.finance_create_transfer_v1(
          v_user_id,
          v_account_1,
          v_account_2,
          2,
          999,
          now(),
          'transfer',
          'be_dom_001_erasure_verify',
          940002
      );

    -- Also exercise the transactions.transfer_id -> transfers FK that makes
    -- delete ordering important.
    update moneytrack.transactions
       set transfer_id = v_transfer_id
     where id = v_tx_id;

    insert into moneytrack.receipts(
        user_id,transaction_id,receipt_date,shop_name,total_amount,currency,status
    ) values (
        v_user_id,v_tx_id,current_date,'BE-DOM erase shop',1.23,v_currency,'parsed'
    ) returning id into v_receipt;

    insert into moneytrack.receipt_items(
        receipt_id,item_name_original,quantity,unit_price,amount,category_id,product_id
    ) values (
        v_receipt,'BE-DOM erase item',1,1.23,1.23,v_category,v_product
    );

    insert into moneytrack.user_delete_requests(
        user_id,confirmation_code,expires_at,created_at
    ) values (
        v_user_id,'ERASE940001',now()+interval '10 minutes',now()
    );

    select * into v_result
      from moneytrack.user_delete_me_v1(v_user_id,null);

    if v_result.status <> 'invalid_command' then
        raise exception 'VERIFY_NULL_CODE_STATUS_FAILED: %', row_to_json(v_result);
    end if;

    if not exists (select 1 from moneytrack.app_users where id=v_user_id) then
        raise exception 'VERIFY_INVALID_COMMAND_DELETED_USER';
    end if;

    select * into v_result
      from moneytrack.user_delete_me_v1(v_user_id,'WRONG');

    if v_result.status <> 'invalid_or_expired' then
        raise exception 'VERIFY_WRONG_CODE_STATUS_FAILED: %', row_to_json(v_result);
    end if;

    if not exists (select 1 from moneytrack.app_users where id=v_user_id) then
        raise exception 'VERIFY_WRONG_CODE_DELETED_USER';
    end if;

    select * into v_result
      from moneytrack.user_delete_me_v1(v_user_id,'ERASE940001');

    if v_result.status <> 'deleted'
       or v_result.deleted_user_id <> v_user_id
       or v_result.deleted_transaction_count <> 1
       or v_result.deleted_transfer_count <> 1
       or v_result.deleted_workspace_count <> 1
    then
        raise exception 'VERIFY_VALID_DELETE_RESULT_FAILED: %', row_to_json(v_result);
    end if;

    if exists (select 1 from moneytrack.app_users where id=v_user_id) then
        raise exception 'VERIFY_TARGET_USER_STILL_EXISTS';
    end if;

    if exists (select 1 from moneytrack.transactions where user_id=v_user_id)
       or exists (select 1 from moneytrack.transfers where user_id=v_user_id)
       or exists (select 1 from moneytrack.receipts where user_id=v_user_id)
       or exists (select 1 from moneytrack.accounts where user_id=v_user_id)
       or exists (select 1 from moneytrack.budget_rules where user_id=v_user_id)
       or exists (select 1 from moneytrack.product_catalog where user_id=v_user_id)
       or exists (select 1 from moneytrack.category_catalog where user_id=v_user_id)
       or exists (select 1 from moneytrack.user_settings where user_id=v_user_id)
       or exists (select 1 from moneytrack.user_currencies where user_id=v_user_id)
       or exists (select 1 from moneytrack.user_default_accounts where user_id=v_user_id)
       or exists (select 1 from moneytrack.user_delete_requests where user_id=v_user_id)
       or exists (select 1 from moneytrack.workspace_members where user_id=v_user_id)
    then
        raise exception 'VERIFY_TARGET_USER_AGGREGATE_LEAKED';
    end if;

    if exists (select 1 from moneytrack.workspaces where id=v_workspace) then
        raise exception 'VERIFY_OWNED_WORKSPACE_STILL_EXISTS';
    end if;

    if not exists (select 1 from moneytrack.app_users where id=v_other_user_id) then
        raise exception 'VERIFY_OTHER_USER_WAS_DELETED';
    end if;

    if not exists (select 1 from moneytrack.workspaces where id=v_other_workspace) then
        raise exception 'VERIFY_OTHER_WORKSPACE_WAS_DELETED';
    end if;

    if exists (
        select 1
          from moneytrack.workspace_members
         where workspace_id=v_workspace
    ) then
        raise exception 'VERIFY_DELETED_WORKSPACE_MEMBERSHIP_LEAKED';
    end if;

    if (select current_workspace_id
          from moneytrack.user_settings
         where user_id=v_other_user_id) is not null
    then
        raise exception 'VERIFY_OTHER_USER_CURRENT_WORKSPACE_NOT_DETACHED';
    end if;

    if exists (
        select 1
          from moneytrack.workspace_members
         where workspace_id=v_other_workspace
           and user_id=v_user_id
    ) then
        raise exception 'VERIFY_TARGET_MEMBERSHIP_IN_FOREIGN_WORKSPACE_LEAKED';
    end if;
end
$verify$;

rollback;
