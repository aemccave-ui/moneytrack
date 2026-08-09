-- MoneyTrack — BE-DOM-004 — rollback-safe budget domain verifier
--
-- Synthetic users/categories/rules only. Entire fixture is rolled back.

begin;

DO $verify$
declare
    v_tg1 bigint := 900000000401;
    v_tg2 bigint := 900000000402;
    v_user1 bigint;
    v_user2 bigint;
    v_category1 bigint;
    v_category2 bigint;
    v_currency text;
    v_rule1 bigint;
    v_rule2 bigint;
    v_status text;
    v_action text;
    v_is_active boolean;
    v_count integer;
begin
    if exists (
        select 1
        from moneytrack.app_users u
        where u.telegram_user_id in (v_tg1, v_tg2)
    ) then
        raise exception 'BE-DOM-004 verifier fixture Telegram ids already exist';
    end if;

    select c.code
      into v_currency
      from moneytrack.currencies c
     where coalesce(c.is_active, true) = true
     order by case when c.code = 'EUR' then 0 else 1 end, c.code
     limit 1;

    if v_currency is null then
        raise exception 'BE-DOM-004 verifier requires one active currency';
    end if;

    insert into moneytrack.app_users (
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        v_tg1, 'be_dom_004_verify_1', 'BE DOM 004 Verify One', 'en', v_currency
    ) returning app_users.id into v_user1;

    insert into moneytrack.app_users (
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        v_tg2, 'be_dom_004_verify_2', 'BE DOM 004 Verify Two', 'en', v_currency
    ) returning app_users.id into v_user2;

    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order
    ) values (
        v_user1, 'BE_DOM_004_A', null, true, 900, now(), true, 900
    ) returning category_catalog.id into v_category1;

    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order, created_at,
        show_in_budget_report, budget_sort_order
    ) values (
        v_user2, 'BE_DOM_004_B', null, true, 900, now(), true, 900
    ) returning category_catalog.id into v_category2;

    -- ------------------------------------------------------------------
    -- 1. Non-resolved upstream state is a no-op and preserves status.
    -- ------------------------------------------------------------------
    select r.status
      into v_status
      from moneytrack.budget_create_rule_v1(
          v_user1,
          'category_not_found',
          v_category1,
          'Verifier unresolved',
          10.00,
          v_currency,
          'monthly',
          1,
          current_date,
          null
      ) r;

    if v_status <> 'category_not_found' then
        raise exception 'unresolved status not preserved: %', v_status;
    end if;

    select count(*)::integer
      into v_count
      from moneytrack.budget_rules br
     where br.user_id = v_user1;

    if v_count <> 0 then
        raise exception 'unresolved create mutated budget_rules';
    end if;

    -- ------------------------------------------------------------------
    -- 2. Required-field validation is fail-closed without mutation.
    -- ------------------------------------------------------------------
    select r.status
      into v_status
      from moneytrack.budget_create_rule_v1(
          v_user1,
          'resolved',
          v_category1,
          'Verifier invalid',
          null,
          v_currency,
          'monthly',
          1,
          current_date,
          null
      ) r;

    if v_status <> 'invalid_command' then
        raise exception 'invalid create contract failed: %', v_status;
    end if;

    -- ------------------------------------------------------------------
    -- 3. Cross-tenant category reference must be rejected.
    -- ------------------------------------------------------------------
    select r.status
      into v_status
      from moneytrack.budget_create_rule_v1(
          v_user1,
          'resolved',
          v_category2,
          'Verifier foreign category',
          20.00,
          v_currency,
          'monthly',
          1,
          current_date,
          null
      ) r;

    if v_status <> 'not_found' then
        raise exception 'foreign category was not rejected: %', v_status;
    end if;

    -- ------------------------------------------------------------------
    -- 4. Successful create returns legacy output/status and owns the row.
    -- ------------------------------------------------------------------
    select r.id, r.status
      into v_rule1, v_status
      from moneytrack.budget_create_rule_v1(
          v_user1,
          'resolved',
          v_category1,
          'Verifier Budget One',
          125.50,
          v_currency,
          'monthly',
          1,
          current_date,
          null
      ) r;

    if v_rule1 is null or v_status <> 'added' then
        raise exception 'valid budget create failed: id %, status %', v_rule1, v_status;
    end if;

    if not exists (
        select 1
        from moneytrack.budget_rules br
        where br.id = v_rule1
          and br.user_id = v_user1
          and br.category_id = v_category1
          and br.amount = 125.50
          and br.currency_code = v_currency
          and br.is_active = true
    ) then
        raise exception 'created budget rule content/ownership mismatch';
    end if;

    select r.id
      into v_rule2
      from moneytrack.budget_create_rule_v1(
          v_user2,
          'resolved',
          v_category2,
          'Verifier Budget Two',
          77.00,
          v_currency,
          'monthly',
          1,
          current_date,
          null
      ) r;

    if v_rule2 is null then
        raise exception 'second tenant rule creation failed';
    end if;

    -- ------------------------------------------------------------------
    -- 5. Invalid command is a no-op.
    -- ------------------------------------------------------------------
    select r.status
      into v_status
      from moneytrack.budget_apply_action_v1(v_user1, null, v_rule1) r;

    if v_status <> 'invalid_command' then
        raise exception 'invalid action contract failed: %', v_status;
    end if;

    -- ------------------------------------------------------------------
    -- 6. Foreign ownership must look like not_found and not mutate target.
    -- ------------------------------------------------------------------
    select r.status
      into v_status
      from moneytrack.budget_apply_action_v1(v_user1, 'disable', v_rule2) r;

    if v_status <> 'not_found' then
        raise exception 'foreign budget action was not rejected: %', v_status;
    end if;

    if (select br.is_active from moneytrack.budget_rules br where br.id = v_rule2) is not true then
        raise exception 'foreign budget action mutated target';
    end if;

    -- Unknown non-null action preserves legacy not_found semantics.
    select r.status
      into v_status
      from moneytrack.budget_apply_action_v1(v_user1, 'unsupported', v_rule1) r;

    if v_status <> 'not_found' then
        raise exception 'unsupported action legacy contract failed: %', v_status;
    end if;

    -- ------------------------------------------------------------------
    -- 7. Disable/enable are owned, deterministic updates.
    -- ------------------------------------------------------------------
    select r.status, r.action, r.is_active
      into v_status, v_action, v_is_active
      from moneytrack.budget_apply_action_v1(v_user1, 'disable', v_rule1) r;

    if v_status <> 'disable' or v_action <> 'disable' or v_is_active is not false then
        raise exception 'disable failed: status %, action %, active %',
            v_status, v_action, v_is_active;
    end if;

    if (select br.is_active from moneytrack.budget_rules br where br.id = v_rule1) is not false then
        raise exception 'disable did not persist false';
    end if;

    select r.status, r.is_active
      into v_status, v_is_active
      from moneytrack.budget_apply_action_v1(v_user1, 'enable', v_rule1) r;

    if v_status <> 'enable' or v_is_active is not true then
        raise exception 'enable failed: status %, active %', v_status, v_is_active;
    end if;

    -- ------------------------------------------------------------------
    -- 8. Delete is owned and repeated delete converges to not_found.
    -- ------------------------------------------------------------------
    select r.status, r.action, r.is_active
      into v_status, v_action, v_is_active
      from moneytrack.budget_apply_action_v1(v_user1, 'delete', v_rule1) r;

    if v_status <> 'delete' or v_action <> 'delete' or v_is_active is not false then
        raise exception 'delete result contract failed';
    end if;

    if exists (
        select 1 from moneytrack.budget_rules br where br.id = v_rule1
    ) then
        raise exception 'delete did not remove rule';
    end if;

    select r.status
      into v_status
      from moneytrack.budget_apply_action_v1(v_user1, 'delete', v_rule1) r;

    if v_status <> 'not_found' then
        raise exception 'repeated delete did not converge to not_found: %', v_status;
    end if;

    raise notice 'BE-DOM-004 verifier PASS: create/status/category-ownership/action-ownership/enable-disable-delete';
end;
$verify$;

rollback;
