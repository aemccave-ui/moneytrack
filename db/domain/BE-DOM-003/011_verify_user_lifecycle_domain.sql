-- MoneyTrack — BE-DOM-003 — rollback-safe verifier
--
-- Synthetic users only. The complete fixture and all mutations are rolled back.

begin;

DO $verify$
declare
    v_tg1 bigint := 900000000301;
    v_tg2 bigint := 900000000302;
    v_user1 bigint;
    v_user2 bigint;
    v_workspace1 bigint;
    v_workspace2 bigint;
    v_workspace_count integer;
    v_account_count integer;
    v_account_count_after integer;
    v_template_account_count integer;
    v_default_count integer;
    v_template_default_count integer;
    v_category_count integer;
    v_template_category_count integer;
    v_language text;
    v_language_before text;
    v_status text;
    v_valid boolean;
    v_currency text;
    v_account_id bigint;
    v_account_name text;
    v_account_code text;
    v_account_type text;
    v_default_account_id bigint;
    v_cross_status text;
    v_request1 bigint;
    v_request2 bigint;
    v_code1 text;
    v_code2 text;
    v_expiry1 timestamptz;
    v_expiry2 timestamptz;
    v_unused_requests integer;
    v_first_request_used timestamptz;
    v_delete_status text;
    v_deleted_user bigint;
begin
    if exists (
        select 1
        from moneytrack.app_users u
        where u.telegram_user_id in (v_tg1, v_tg2)
    ) then
        raise exception 'BE-DOM-003 verifier fixture Telegram ids already exist';
    end if;

    -- ---------------------------------------------------------------------
    -- 1. Canonical bootstrap: complete aggregate and output contract.
    -- ---------------------------------------------------------------------
    select b.user_id, b.workspace_id
      into v_user1, v_workspace1
      from moneytrack.user_bootstrap_v1(
          v_tg1,
          'be_dom_003_verify_1',
          'BE DOM 003 Verify One',
          'en'
      ) b;

    if v_user1 is null or v_workspace1 is null then
        raise exception 'bootstrap did not return user/workspace';
    end if;

    if not exists (
        select 1
        from moneytrack.app_users u
        where u.id = v_user1
          and u.telegram_user_id = v_tg1
    ) then
        raise exception 'bootstrap app_user missing';
    end if;

    select count(*)::integer
      into v_workspace_count
      from moneytrack.workspaces w
     where w.owner_user_id = v_user1
       and w.workspace_type = 'personal'
       and coalesce(w.is_active, true) = true;

    if v_workspace_count <> 1 then
        raise exception 'expected one active personal workspace, got %', v_workspace_count;
    end if;

    if not exists (
        select 1
        from moneytrack.workspace_members wm
        where wm.workspace_id = v_workspace1
          and wm.user_id = v_user1
          and wm.role = 'owner'
          and wm.is_active = true
    ) then
        raise exception 'bootstrap owner membership missing';
    end if;

    if not exists (
        select 1
        from moneytrack.user_settings us
        where us.user_id = v_user1
          and us.current_workspace_id = v_workspace1
          and us.base_currency is not null
    ) then
        raise exception 'bootstrap user_settings missing/incomplete';
    end if;

    select count(*)::integer
      into v_template_account_count
      from moneytrack.accounts a
     where a.user_id = 0;

    select count(*)::integer
      into v_account_count
      from moneytrack.accounts a
     where a.user_id = v_user1;

    if v_account_count < v_template_account_count then
        raise exception 'bootstrap accounts incomplete: target %, template %',
            v_account_count, v_template_account_count;
    end if;

    select count(*)::integer
      into v_template_default_count
      from moneytrack.user_default_accounts uda
     where uda.user_id = 0;

    select count(*)::integer
      into v_default_count
      from moneytrack.user_default_accounts uda
     where uda.user_id = v_user1;

    if v_default_count < v_template_default_count then
        raise exception 'bootstrap default accounts incomplete: target %, template %',
            v_default_count, v_template_default_count;
    end if;

    select count(*)::integer
      into v_template_category_count
      from moneytrack.category_catalog c
     where c.user_id = 0;

    select count(*)::integer
      into v_category_count
      from moneytrack.category_catalog c
     where c.user_id = v_user1;

    if v_category_count < v_template_category_count then
        raise exception 'bootstrap categories incomplete: target %, template %',
            v_category_count, v_template_category_count;
    end if;

    -- ---------------------------------------------------------------------
    -- 2. Bootstrap idempotency: no duplicate workspace/accounts/defaults.
    -- ---------------------------------------------------------------------
    perform 1
      from moneytrack.user_bootstrap_v1(
          v_tg1,
          'be_dom_003_verify_1_updated',
          'BE DOM 003 Verify One Updated',
          'ru'
      );

    select count(*)::integer
      into v_account_count_after
      from moneytrack.accounts a
     where a.user_id = v_user1;

    if v_account_count_after <> v_account_count then
        raise exception 'bootstrap duplicated accounts: before %, after %',
            v_account_count, v_account_count_after;
    end if;

    select count(*)::integer
      into v_workspace_count
      from moneytrack.workspaces w
     where w.owner_user_id = v_user1
       and w.workspace_type = 'personal'
       and coalesce(w.is_active, true) = true;

    if v_workspace_count <> 1 then
        raise exception 'repeat bootstrap duplicated personal workspace';
    end if;

    select count(*)::integer
      into v_default_count
      from moneytrack.user_default_accounts uda
     where uda.user_id = v_user1;

    if v_default_count < v_template_default_count then
        raise exception 'repeat bootstrap lost default-account mappings';
    end if;

    -- ---------------------------------------------------------------------
    -- 3. Second tenant for isolation and erasure integration.
    -- ---------------------------------------------------------------------
    select b.user_id, b.workspace_id
      into v_user2, v_workspace2
      from moneytrack.user_bootstrap_v1(
          v_tg2,
          'be_dom_003_verify_2',
          'BE DOM 003 Verify Two',
          'en'
      ) b;

    if v_user2 is null or v_user2 = v_user1 then
        raise exception 'second bootstrap user invalid';
    end if;

    -- ---------------------------------------------------------------------
    -- 4. Language preference: supported update + unsupported no-op.
    -- ---------------------------------------------------------------------
    select l.code
      into v_language
      from moneytrack.languages l
     order by case when l.code = 'en' then 0 else 1 end, l.code
     limit 1;

    if v_language is null then
        raise exception 'no language fixture available';
    end if;

    select r.status, r.is_valid
      into v_status, v_valid
      from moneytrack.user_set_language_v1(v_user1, v_language) r;

    if v_status <> 'updated' or v_valid is not true then
        raise exception 'valid language update failed: status %, valid %', v_status, v_valid;
    end if;

    select us.language_code
      into v_language_before
      from moneytrack.user_settings us
     where us.user_id = v_user1;

    select r.status, r.is_valid
      into v_status, v_valid
      from moneytrack.user_set_language_v1(v_user1, '__unsupported__') r;

    if v_status <> 'unsupported_language' or v_valid is not false then
        raise exception 'unsupported language contract failed: status %, valid %', v_status, v_valid;
    end if;

    if (select us.language_code from moneytrack.user_settings us where us.user_id = v_user1)
       is distinct from v_language_before then
        raise exception 'unsupported language mutated settings';
    end if;

    -- ---------------------------------------------------------------------
    -- 5. Currency preference: valid update + invalid no-op.
    -- ---------------------------------------------------------------------
    select c.code
      into v_currency
      from moneytrack.currencies c
     where coalesce(c.is_active, true) = true
     order by case when c.code = 'EUR' then 0 else 1 end, c.code
     limit 1;

    if v_currency is null then
        raise exception 'no active currency fixture available';
    end if;

    select r.status, r.is_valid
      into v_status, v_valid
      from moneytrack.user_set_currency_v1(v_user1, 'report', v_currency) r;

    if v_status <> 'valid' or v_valid is not true then
        raise exception 'valid currency update failed: status %, valid %', v_status, v_valid;
    end if;

    if (select us.report_currency from moneytrack.user_settings us where us.user_id = v_user1)
       is distinct from v_currency then
        raise exception 'report currency not persisted';
    end if;

    select r.status, r.is_valid
      into v_status, v_valid
      from moneytrack.user_set_currency_v1(v_user1, 'base', '__BAD__') r;

    if v_status <> 'invalid_currency' or v_valid is not false then
        raise exception 'invalid currency contract failed: status %, valid %', v_status, v_valid;
    end if;

    -- ---------------------------------------------------------------------
    -- 6. Default-account preference + cross-tenant isolation.
    -- ---------------------------------------------------------------------
    select a.id, a.name, a.code, a.account_type, a.currency_code
      into v_account_id, v_account_name, v_account_code, v_account_type, v_currency
      from moneytrack.accounts a
     where a.user_id = v_user1
       and coalesce(a.is_active, true) = true
     order by a.id
     limit 1;

    if v_account_id is null then
        raise exception 'no bootstrapped account fixture';
    end if;

    select r.status
      into v_status
      from moneytrack.user_set_default_account_v1(
          v_user1,
          v_currency,
          v_account_code
      ) r;

    if v_status <> 'updated' then
        raise exception 'default-account update failed: %', v_status;
    end if;

    select uda.account_id
      into v_default_account_id
      from moneytrack.user_default_accounts uda
     where uda.user_id = v_user1
       and uda.currency_code = v_currency;

    if v_default_account_id is distinct from v_account_id then
        raise exception 'default-account mapping mismatch: expected %, got %',
            v_account_id, v_default_account_id;
    end if;

    insert into moneytrack.accounts (
        user_id, code, name, account_type, currency_code,
        is_active, created_at, sort_order, parent_id
    ) values (
        v_user1,
        'BE_DOM_003_PRIVATE',
        'BE DOM 003 PRIVATE ACCOUNT',
        v_account_type,
        v_currency,
        true,
        now(),
        9999,
        null
    );

    select r.status
      into v_cross_status
      from moneytrack.user_set_default_account_v1(
          v_user2,
          v_currency,
          'BE_DOM_003_PRIVATE'
      ) r;

    if v_cross_status <> 'account_not_found' then
        raise exception 'cross-tenant account isolation failed: %', v_cross_status;
    end if;

    -- ---------------------------------------------------------------------
    -- 7. Delete request issuance: exactly one active request per user.
    -- ---------------------------------------------------------------------
    select r.id, r.confirmation_code, r.expires_at
      into v_request1, v_code1, v_expiry1
      from moneytrack.user_create_delete_request_v1(v_user2) r;

    select r.id, r.confirmation_code, r.expires_at
      into v_request2, v_code2, v_expiry2
      from moneytrack.user_create_delete_request_v1(v_user2) r;

    if v_request1 is null or v_request2 is null or v_request1 = v_request2 then
        raise exception 'delete request issuance ids invalid';
    end if;

    if v_code2 is null or length(v_code2) <> 6 or v_expiry2 <= now() then
        raise exception 'delete request output invalid';
    end if;

    select count(*)::integer
      into v_unused_requests
      from moneytrack.user_delete_requests r
     where r.user_id = v_user2
       and r.used_at is null;

    if v_unused_requests <> 1 then
        raise exception 'expected one unused delete request, got %', v_unused_requests;
    end if;

    select r.used_at
      into v_first_request_used
      from moneytrack.user_delete_requests r
     where r.id = v_request1;

    if v_first_request_used is null then
        raise exception 'prior delete request was not invalidated';
    end if;

    -- Integration only: existing BE-DOM-001 destructive boundary must consume
    -- the new request contract. This remains synthetic and is rolled back.
    select d.status, d.deleted_user_id
      into v_delete_status, v_deleted_user
      from moneytrack.user_delete_me_v1(v_user2, v_code2) d;

    if v_delete_status <> 'deleted' or v_deleted_user is distinct from v_user2 then
        raise exception 'user_delete_me_v1 integration failed: status %, user %',
            v_delete_status, v_deleted_user;
    end if;

    if exists (select 1 from moneytrack.app_users u where u.id = v_user2) then
        raise exception 'synthetic erased user survived';
    end if;

    if not exists (select 1 from moneytrack.app_users u where u.id = v_user1) then
        raise exception 'cross-tenant survivor was deleted';
    end if;

    raise notice 'BE-DOM-003 verifier PASS: bootstrap/idempotency/preferences/default-account/delete-request/erasure integration';
end;
$verify$;

rollback;
