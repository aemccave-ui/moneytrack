-- MoneyTrack — BE-DOM-002 — rollback-safe verifier
-- Synthetic users only. The whole verification ends with ROLLBACK.

begin;

do $verify$
declare
    v_user_id bigint;
    v_other_user_id bigint;
    v_account_id bigint;
    v_other_category_id bigint;
    v_category_id bigint;
    v_category_code text;
    v_template_category_count integer;
    v_user_category_count integer;
    v_template_translation_count integer;
    v_user_translation_count integer;
    v_bootstrap_status text;
    v_bootstrap_categories integer;
    v_bootstrap_translations integer;
    v_status text;
    v_tx_id bigint;
    v_receipt_id bigint;
    v_item_count integer;
    v_duplicate_id bigint;
    v_product_id bigint;
    v_receipt_item_id bigint;
    v_product_count integer;
    v_propagated_item_count integer;
    v_manual_status text;
    v_manual_category_id bigint;
    v_before_tx_count integer;
    v_after_tx_count integer;
    v_before_receipt_count integer;
    v_after_receipt_count integer;
begin
    insert into moneytrack.app_users (
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        900000000101, 'be_dom_002_verify', 'BE-DOM-002', 'en', 'EUR'
    ) returning id into v_user_id;

    insert into moneytrack.app_users (
        telegram_user_id, username, first_name, language_code, default_currency
    ) values (
        900000000102, 'be_dom_002_verify_other', 'BE-DOM-002 Other', 'en', 'EUR'
    ) returning id into v_other_user_id;

    insert into moneytrack.user_settings (
        user_id, base_currency, report_currency, language_code
    ) values
        (v_user_id, 'EUR', 'EUR', 'en'),
        (v_other_user_id, 'EUR', 'EUR', 'en');

    insert into moneytrack.accounts (
        user_id, code, name, account_type, currency_code, is_active
    ) values (
        v_user_id, 'be_dom_002.eur', 'BE-DOM-002 EUR', 'bank', 'EUR', true
    ) returning id into v_account_id;

    select count(*)::integer
      into v_template_category_count
      from moneytrack.category_catalog c
     where c.user_id = 0;

    if v_template_category_count = 0 then
        raise exception 'VERIFY_SETUP_FAILED: template user 0 has no categories';
    end if;

    select b.status, b.inserted_category_count, b.inserted_translation_count
      into v_bootstrap_status, v_bootstrap_categories, v_bootstrap_translations
      from moneytrack.catalog_ensure_user_categories_v1(v_user_id) b;

    if v_bootstrap_status <> 'ready' then
        raise exception 'CATALOG_BOOTSTRAP_STATUS_FAILED: %', v_bootstrap_status;
    end if;

    select count(*)::integer
      into v_user_category_count
      from moneytrack.category_catalog c
     where c.user_id = v_user_id;

    if v_user_category_count <> v_template_category_count then
        raise exception 'CATALOG_BOOTSTRAP_COUNT_FAILED: template %, user %',
            v_template_category_count, v_user_category_count;
    end if;

    select count(*)::integer
      into v_template_translation_count
      from moneytrack.category_catalog_translations tr
      join moneytrack.category_catalog c on c.id = tr.category_id
     where c.user_id = 0;

    select count(*)::integer
      into v_user_translation_count
      from moneytrack.category_catalog_translations tr
      join moneytrack.category_catalog c on c.id = tr.category_id
     where c.user_id = v_user_id;

    if v_user_translation_count <> v_template_translation_count then
        raise exception 'CATALOG_TRANSLATION_COUNT_FAILED: template %, user %',
            v_template_translation_count, v_user_translation_count;
    end if;

    -- Second bootstrap must be idempotent.
    select b.status, b.inserted_category_count, b.inserted_translation_count
      into v_bootstrap_status, v_bootstrap_categories, v_bootstrap_translations
      from moneytrack.catalog_ensure_user_categories_v1(v_user_id) b;

    if v_bootstrap_categories <> 0 or v_bootstrap_translations <> 0 then
        raise exception 'CATALOG_BOOTSTRAP_NOT_IDEMPOTENT: categories %, translations %',
            v_bootstrap_categories, v_bootstrap_translations;
    end if;

    select c.id, c.code
      into v_category_id, v_category_code
      from moneytrack.category_catalog c
     where c.user_id = v_user_id
       and coalesce(c.is_active, true) = true
     order by c.id
     limit 1;

    if v_category_id is null then
        raise exception 'VERIFY_SETUP_FAILED: no synthetic user category';
    end if;

    -- Atomic happy path: transaction + receipt + product + item.
    select r.status, r.transaction_id, r.receipt_id,
           r.created_item_count, r.duplicate_receipt_id
      into v_status, v_tx_id, v_receipt_id, v_item_count, v_duplicate_id
      from moneytrack.receipt_ingest_v1(
          v_user_id,
          v_account_id,
          3.21,
          'EUR',
          'BE-DOM-002 VERIFY SHOP',
          current_date,
          'BE-DOM-002-FILE-1',
          'BE-DOM-002-FP-1',
          jsonb_build_object('verify', true),
          jsonb_build_array(
              jsonb_build_object(
                  'item_name_original', 'BE-DOM-002 Milk',
                  'item_language', null,
                  'quantity', 1,
                  'unit_price', 3.21,
                  'amount', 3.21,
                  'category_id', null
              )
          )
      ) r;

    if v_status <> 'created' or v_tx_id is null or v_receipt_id is null or v_item_count <> 1 then
        raise exception 'RECEIPT_INGEST_FAILED: status %, tx %, receipt %, items %',
            v_status, v_tx_id, v_receipt_id, v_item_count;
    end if;

    if not exists (
        select 1
          from moneytrack.receipts r
         where r.id = v_receipt_id
           and r.user_id = v_user_id
           and r.transaction_id = v_tx_id
           and r.telegram_file_id = 'BE-DOM-002-FILE-1'
           and r.receipt_fingerprint = 'BE-DOM-002-FP-1'
    ) then
        raise exception 'RECEIPT_ROW_MISSING';
    end if;

    if not exists (
        select 1
          from moneytrack.transactions t
         where t.id = v_tx_id
           and t.user_id = v_user_id
           and t.account_id = v_account_id
           and t.transaction_type = 'expense'
           and t.amount_original = 3.21
           and t.currency_original = 'EUR'
    ) then
        raise exception 'FINANCE_TRANSACTION_ROW_MISSING';
    end if;

    select ri.id, ri.product_id
      into v_receipt_item_id, v_product_id
      from moneytrack.receipt_items ri
     where ri.receipt_id = v_receipt_id
     limit 1;

    if v_receipt_item_id is null or v_product_id is null then
        raise exception 'RECEIPT_ITEM_OR_PRODUCT_MISSING';
    end if;

    if not exists (
        select 1
          from moneytrack.product_catalog pc
         where pc.id = v_product_id
           and pc.user_id = v_user_id
           and pc.product_key = 'be_dom_002_milk'
    ) then
        raise exception 'PRODUCT_UPSERT_FAILED';
    end if;

    -- Exact duplicate must replay without creating another finance transaction.
    select r.status, r.transaction_id, r.receipt_id,
           r.created_item_count, r.duplicate_receipt_id
      into v_status, v_tx_id, v_receipt_id, v_item_count, v_duplicate_id
      from moneytrack.receipt_ingest_v1(
          v_user_id,
          v_account_id,
          3.21,
          'EUR',
          'BE-DOM-002 VERIFY SHOP',
          current_date,
          'BE-DOM-002-FILE-1',
          'BE-DOM-002-FP-1',
          '{}'::jsonb,
          '[]'::jsonb
      ) r;

    if v_status <> 'duplicate_exact' or v_duplicate_id is null then
        raise exception 'EXACT_DUPLICATE_GATE_FAILED: %, %', v_status, v_duplicate_id;
    end if;

    -- Different file, same fingerprint => semantic duplicate.
    select r.status, r.duplicate_receipt_id
      into v_status, v_duplicate_id
      from moneytrack.receipt_ingest_v1(
          v_user_id,
          v_account_id,
          3.21,
          'EUR',
          'BE-DOM-002 VERIFY SHOP',
          current_date,
          'BE-DOM-002-FILE-2',
          'BE-DOM-002-FP-1',
          '{}'::jsonb,
          '[]'::jsonb
      ) r;

    if v_status <> 'duplicate_semantic' or v_duplicate_id is null then
        raise exception 'SEMANTIC_DUPLICATE_GATE_FAILED: %, %', v_status, v_duplicate_id;
    end if;

    -- Batch assignment owns product validation and receipt-item propagation.
    select a.status, a.updated_product_count, a.updated_item_count
      into v_status, v_product_count, v_propagated_item_count
      from moneytrack.receipt_assign_categories_v1(
          v_user_id,
          (select id from moneytrack.receipts where telegram_file_id = 'BE-DOM-002-FILE-1' and user_id = v_user_id),
          jsonb_build_array(
              jsonb_build_object(
                  'product_id', v_product_id,
                  'category_id', v_category_id
              )
          )
      ) a;

    if v_status <> 'updated' or v_product_count <> 1 or v_propagated_item_count <> 1 then
        raise exception 'CATEGORY_ASSIGNMENT_FAILED: status %, products %, items %',
            v_status, v_product_count, v_propagated_item_count;
    end if;

    if not exists (
        select 1
        from moneytrack.receipt_items ri
        join moneytrack.product_catalog pc on pc.id = ri.product_id
        where ri.id = v_receipt_item_id
          and ri.category_id = v_category_id
          and pc.category_id = v_category_id
    ) then
        raise exception 'CATEGORY_PROPAGATION_FAILED';
    end if;

    -- Manual item categorization preserves the existing code/name matching contract.
    select m.status, m.category_id
      into v_manual_status, v_manual_category_id
      from moneytrack.receipt_set_item_category_v1(
          v_user_id,
          v_receipt_item_id,
          v_category_code
      ) m;

    if v_manual_status <> 'updated' or v_manual_category_id <> v_category_id then
        raise exception 'MANUAL_CATEGORY_UPDATE_FAILED: %, %',
            v_manual_status, v_manual_category_id;
    end if;

    -- Another tenant cannot mutate this receipt item.
    select m.status
      into v_manual_status
      from moneytrack.receipt_set_item_category_v1(
          v_other_user_id,
          v_receipt_item_id,
          v_category_code
      ) m;

    if v_manual_status <> 'item_not_found' then
        raise exception 'TENANT_ISOLATION_FAILED: %', v_manual_status;
    end if;

    -- Build one category belonging to the other tenant for atomic-failure proof.
    insert into moneytrack.category_catalog (
        user_id, code, parent_id, is_active, sort_order,
        show_in_budget_report
    ) values (
        v_other_user_id, 'be_dom_002_foreign', null, true, 999, true
    ) returning id into v_other_category_id;

    select count(*)::integer
      into v_before_tx_count
      from moneytrack.transactions t
     where t.user_id = v_user_id;

    select count(*)::integer
      into v_before_receipt_count
      from moneytrack.receipts r
     where r.user_id = v_user_id;

    begin
        perform *
        from moneytrack.receipt_ingest_v1(
            v_user_id,
            v_account_id,
            9.99,
            'EUR',
            'BE-DOM-002 FAIL',
            current_date,
            'BE-DOM-002-FILE-FAIL',
            'BE-DOM-002-FP-FAIL',
            '{}'::jsonb,
            jsonb_build_array(
                jsonb_build_object(
                    'item_name_original', 'BE-DOM-002 Invalid Tenant Item',
                    'quantity', 1,
                    'unit_price', 9.99,
                    'amount', 9.99,
                    'category_id', v_other_category_id
                )
            )
        );

        raise exception 'EXPECTED_FOREIGN_CATEGORY_FAILURE_DID_NOT_OCCUR';
    exception
        when sqlstate 'P0002' then
            null;
    end;

    select count(*)::integer
      into v_after_tx_count
      from moneytrack.transactions t
     where t.user_id = v_user_id;

    select count(*)::integer
      into v_after_receipt_count
      from moneytrack.receipts r
     where r.user_id = v_user_id;

    if v_after_tx_count <> v_before_tx_count
       or v_after_receipt_count <> v_before_receipt_count
       or exists (
           select 1 from moneytrack.receipts r
           where r.user_id = v_user_id
             and r.telegram_file_id = 'BE-DOM-002-FILE-FAIL'
       )
       or exists (
           select 1 from moneytrack.transactions t
           where t.user_id = v_user_id
             and t.description = 'BE-DOM-002 FAIL'
       )
    then
        raise exception 'ATOMIC_ROLLBACK_FAILED: tx %->%, receipt %->%',
            v_before_tx_count, v_after_tx_count,
            v_before_receipt_count, v_after_receipt_count;
    end if;
end;
$verify$;

rollback;
