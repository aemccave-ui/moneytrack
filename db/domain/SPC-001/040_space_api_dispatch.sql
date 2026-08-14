-- MoneyTrack — SPC-001 — protected financial API dispatcher
--
-- SOURCE ONLY until controlled runtime apply.
-- n8n remains transport/auth only: it passes verified Telegram identity, the
-- untrusted X-MoneyTrack-Space-Id value, route identity, query and body. This
-- dispatcher resolves the actor, asserts current membership, and delegates to
-- versioned Space-native domain functions. Unknown routes fail closed.

begin;

create or replace function moneytrack.spc001_parse_bigint_csv_v1(
    p_value text,
    p_null_when_blank boolean default true
)
returns bigint[]
language plpgsql
immutable
as $function$
declare
    v_parts text[];
    v_part text;
    v_result bigint[] := '{}'::bigint[];
begin
    if p_value is null or btrim(p_value)='' then
        if p_null_when_blank then return null; end if;
        return '{}'::bigint[];
    end if;

    v_parts := string_to_array(p_value,',');
    foreach v_part in array v_parts loop
        v_part := btrim(v_part);
        if v_part !~ '^[0-9]+$' then
            raise exception 'ID_LIST_INVALID' using errcode='22023';
        end if;
        v_result := array_append(v_result,v_part::bigint);
    end loop;

    return array(select distinct x from unnest(v_result) x order by x);
end;
$function$;

create or replace function moneytrack.spc001_json_bigint_array_v1(
    p_value jsonb,
    p_null_when_missing boolean default false
)
returns bigint[]
language plpgsql
immutable
as $function$
declare
    v_text text;
    v_result bigint[];
begin
    if p_value is null or p_value='null'::jsonb then
        if p_null_when_missing then return null; end if;
        return '{}'::bigint[];
    end if;
    if jsonb_typeof(p_value)<>'array' then
        raise exception 'ID_ARRAY_INVALID' using errcode='22023';
    end if;
    select array_agg(distinct value::bigint order by value::bigint)
      into v_result
      from jsonb_array_elements_text(p_value)
     where value ~ '^[0-9]+$';
    if (select count(*) from jsonb_array_elements(p_value))
       <> coalesce(cardinality(v_result),0)
       and (select count(distinct value) from jsonb_array_elements_text(p_value))
          <> coalesce(cardinality(v_result),0)
    then
        -- The exact cardinality may shrink because duplicates are allowed, so
        -- validate each raw element independently as the authoritative check.
        if exists(select 1 from jsonb_array_elements_text(p_value) e(value) where value !~ '^[0-9]+$') then
            raise exception 'ID_ARRAY_INVALID' using errcode='22023';
        end if;
    end if;
    return coalesce(v_result,'{}'::bigint[]);
end;
$function$;

create or replace function moneytrack.spc001_financial_api_dispatch_v1(
    p_telegram_user_id bigint,
    p_space_id bigint,
    p_method text,
    p_path text,
    p_query jsonb default '{}'::jsonb,
    p_body jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
as $function$
declare
    v_actor bigint;
    v_method text:=upper(coalesce(p_method,''));
    v_path text:=ltrim(coalesce(p_path,''),'/');
    v_query jsonb:=coalesce(p_query,'{}'::jsonb);
    v_body jsonb:=coalesce(p_body,'{}'::jsonb);
    v_result jsonb;
    v_id bigint;
    v_id2 bigint;
    v_account_id bigint;
    v_category_id bigint;
    v_request_id bigint;
    v_amount numeric;
    v_date timestamptz;
    v_date_from date;
    v_date_to date;
    v_type text;
    v_currency text;
    v_name text;
    v_accounts bigint[];
    v_income bigint[];
    v_expense bigint[];
    v_row record;
begin
    if v_path not in (
        'api/v1/dashboard',
        'api/v1/accounts',
        'api/v1/accounts/archived',
        'api/v1/transaction-reference',
        'api/v1/receipt',
        'api/v1/receipt/accounting',
        'api/v1/receipt-item/category',
        'api/v1/categories',
        'api/v1/transaction',
        'api/v1/transfer',
        'api/v1/transactions',
        'api/v1/accounts-explorer-summary',
        'api/v1/filter-presets',
        'api/v1/accounts/copy',
        'api/v1/accounts/move',
        'api/v1/accounts/archive',
        'api/v1/accounts/restore',
        'api/v1/accounts/move-operations/preview',
        'api/v1/accounts/move-operations'
    ) then
        raise exception 'SPC001_API_ROUTE_NOT_ALLOWED' using errcode='42501';
    end if;

    v_actor:=moneytrack.spc001_resolve_actor_user_id_v1(p_telegram_user_id);
    -- p_space_id is client-provided/untrusted. This is the canonical third
    -- runtime predicate after Telegram identity and SEC-001 unlock.
    perform moneytrack.assert_space_member_v1(v_actor,p_space_id);

    -- Dashboard -------------------------------------------------------------
    if v_method='GET' and v_path='api/v1/dashboard' then
        select to_jsonb(d) into v_result
          from moneytrack.finance_dashboard_space_read_model_v1(v_actor,p_space_id,current_date) d;
        return coalesce(v_result,'{}'::jsonb);
    end if;

    -- Accounts --------------------------------------------------------------
    if v_method='GET' and v_path='api/v1/accounts' then
        select jsonb_build_object(
          'actor_user_id',a.actor_user_id,'space_id',a.space_id,
          'base_currency',a.base_currency,'total_base',a.total_base,
          'default_account',a.default_account,'accounts',a.accounts
        ) into v_result
        from moneytrack.finance_accounts_space_read_model_v1(v_actor,p_space_id) a;
        return coalesce(v_result,'{}'::jsonb);
    end if;

    if v_method='GET' and v_path='api/v1/accounts/archived' then
        select jsonb_build_object('accounts',a.accounts) into v_result
          from moneytrack.accounts_archived_space_read_v1(v_actor,p_space_id) a;
        return coalesce(v_result,jsonb_build_object('accounts','[]'::jsonb));
    end if;

    if v_method='POST' and v_path='api/v1/accounts' then
        v_name:=nullif(btrim(v_body->>'name'),'');
        v_id:=nullif(v_body->>'parent_id','')::bigint;
        select jsonb_build_object('account',a.account) into v_result
          from moneytrack.account_create_space_v1(
            v_actor,p_space_id,v_name,v_body->>'account_type',v_body->>'currency_code',v_id,v_body->>'code'
          ) a;
        return v_result;
    end if;

    if v_method='PATCH' and v_path='api/v1/accounts' then
        v_id:=nullif(v_body->>'account_id','')::bigint;
        select jsonb_build_object('account',a.account) into v_result
          from moneytrack.account_edit_space_v1(v_actor,p_space_id,v_id,v_body->>'name',v_body->>'account_type') a;
        return v_result;
    end if;

    if v_method='DELETE' and v_path='api/v1/accounts' then
        v_id:=nullif(v_query->>'id','')::bigint;
        select to_jsonb(a) into v_result from moneytrack.account_delete_space_v1(v_actor,p_space_id,v_id) a;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/accounts/copy' then
        v_id:=nullif(v_body->>'account_id','')::bigint;
        select jsonb_build_object('account',a.account) into v_result
          from moneytrack.account_copy_space_v1(v_actor,p_space_id,v_id) a;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/accounts/move' then
        v_id:=nullif(v_body->>'account_id','')::bigint;
        v_id2:=nullif(v_body->>'parent_id','')::bigint;
        select to_jsonb(a) into v_result from moneytrack.account_move_space_v1(v_actor,p_space_id,v_id,v_id2) a;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/accounts/archive' then
        v_id:=nullif(v_body->>'account_id','')::bigint;
        select to_jsonb(a) into v_result from moneytrack.account_archive_space_v1(v_actor,p_space_id,v_id) a;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/accounts/restore' then
        v_id:=nullif(v_body->>'account_id','')::bigint;
        select to_jsonb(a) into v_result from moneytrack.account_restore_space_v1(v_actor,p_space_id,v_id) a;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/accounts/move-operations/preview' then
        v_id:=nullif(v_body->>'source_account_id','')::bigint;
        v_id2:=nullif(v_body->>'target_account_id','')::bigint;
        select to_jsonb(a) into v_result from moneytrack.account_move_operations_preview_space_v1(v_actor,p_space_id,v_id,v_id2) a;
        return v_result;
    end if;

    if v_method='POST' and v_path='api/v1/accounts/move-operations' then
        v_id:=nullif(v_body->>'source_account_id','')::bigint;
        v_id2:=nullif(v_body->>'target_account_id','')::bigint;
        select to_jsonb(a) into v_result from moneytrack.account_move_operations_space_v1(v_actor,p_space_id,v_id,v_id2) a;
        return v_result;
    end if;

    -- References/categories -------------------------------------------------
    if v_method='GET' and v_path='api/v1/transaction-reference' then
        select jsonb_build_object('currencies',r.currencies,'categories',r.categories) into v_result
          from moneytrack.finance_transaction_reference_space_v1(v_actor,p_space_id) r;
        return v_result;
    end if;

    if v_method='PATCH' and v_path='api/v1/categories' then
        v_category_id:=nullif(v_body->>'category_id','')::bigint;
        select jsonb_build_object('category',c.category) into v_result
          from moneytrack.category_update_space_v1(v_actor,p_space_id,v_category_id,v_body->>'name',v_body->>'flow_type') c;
        return v_result;
    end if;

    -- Ordinary transactions -------------------------------------------------
    if v_method='POST' and v_path='api/v1/transaction' then
        v_account_id:=nullif(v_body->>'account_id','')::bigint;
        v_category_id:=nullif(v_body->>'category_id','')::bigint;
        v_request_id:=nullif(v_body->>'request_id','')::bigint;
        v_amount:=nullif(v_body->>'amount_original','')::numeric;
        v_date:=nullif(v_body->>'transaction_date','')::timestamptz;
        select jsonb_build_object('transaction',to_jsonb(t)) into v_result
          from moneytrack.finance_create_transaction_space_v1(
            v_actor,p_space_id,v_account_id,v_body->>'transaction_type',v_amount,v_body->>'currency_original',
            v_body->>'description',v_date,'manual',v_request_id,v_category_id
          ) t;
        return v_result;
    end if;

    if v_method='PATCH' and v_path='api/v1/transaction' then
        v_id:=nullif(v_body->>'transaction_id','')::bigint;
        v_account_id:=nullif(v_body->>'account_id','')::bigint;
        v_category_id:=nullif(v_body->>'category_id','')::bigint;
        v_amount:=nullif(v_body->>'amount_original','')::numeric;
        v_date:=nullif(v_body->>'transaction_date','')::timestamptz;
        select jsonb_build_object('transaction',to_jsonb(t)) into v_result
          from moneytrack.finance_update_transaction_space_v1(
            v_actor,p_space_id,v_id,v_account_id,v_body->>'transaction_type',v_amount,
            v_body->>'currency_original',v_body->>'description',v_date,v_category_id
          ) t;
        return v_result;
    end if;

    if v_method='DELETE' and v_path='api/v1/transaction' then
        v_id:=nullif(v_query->>'id','')::bigint;
        select to_jsonb(t) into v_result from moneytrack.finance_delete_transaction_space_v1(v_actor,p_space_id,v_id) t;
        return v_result;
    end if;

    -- Transfer editor -------------------------------------------------------
    if v_path='api/v1/transfer' then
        if v_method='GET' then
            v_id:=coalesce(nullif(v_query->>'id','')::bigint,nullif(v_query->>'transfer_id','')::bigint);
            select jsonb_build_object('transfer',to_jsonb(t)) into v_result
              from moneytrack.finance_get_transfer_space_v1(v_actor,p_space_id,v_id) t;
            return v_result;
        elsif v_method='POST' then
            v_id:=nullif(v_body->>'from_account_id','')::bigint;
            v_id2:=nullif(v_body->>'to_account_id','')::bigint;
            v_amount:=nullif(v_body->>'from_amount','')::numeric;
            v_date:=nullif(v_body->>'transfer_date','')::timestamptz;
            v_type:=coalesce(nullif(v_body->>'transfer_type',''),'transfer');
            v_request_id:=nullif(v_body->>'request_id','')::bigint;
            select jsonb_build_object('transfer',to_jsonb(t)) into v_result
              from moneytrack.finance_create_transfer_space_v1(
                v_actor,p_space_id,v_id,v_id2,v_amount,null,v_date,v_type,'manual',v_request_id
              ) t;
            return v_result;
        elsif v_method='PATCH' then
            v_id:=nullif(v_body->>'transfer_id','')::bigint;
            v_account_id:=nullif(v_body->>'from_account_id','')::bigint;
            v_id2:=nullif(v_body->>'to_account_id','')::bigint;
            v_amount:=nullif(v_body->>'from_amount','')::numeric;
            v_date:=nullif(v_body->>'transfer_date','')::timestamptz;
            v_type:=coalesce(nullif(v_body->>'transfer_type',''),'transfer');
            select jsonb_build_object('transfer',to_jsonb(t)) into v_result
              from moneytrack.finance_update_transfer_space_v1(v_actor,p_space_id,v_id,v_account_id,v_id2,v_amount,v_date,v_type) t;
            return v_result;
        elsif v_method='DELETE' then
            v_id:=coalesce(nullif(v_query->>'id','')::bigint,nullif(v_query->>'transfer_id','')::bigint);
            select jsonb_build_object('transfer',to_jsonb(t)) into v_result
              from moneytrack.finance_delete_transfer_space_v1(v_actor,p_space_id,v_id) t;
            return v_result;
        end if;
    end if;

    -- Receipt projection ----------------------------------------------------
    if v_method='GET' and v_path='api/v1/receipt' then
        v_id:=nullif(v_query->>'transaction_id','')::bigint;
        v_result:=jsonb_build_object('receipt',moneytrack.receipt_projection_api_read_v1(v_actor,p_space_id,v_id));
        return v_result;
    end if;

    if v_method='PATCH' and v_path='api/v1/receipt/accounting' then
        v_id:=nullif(v_body->>'receipt_id','')::bigint;
        v_account_id:=nullif(v_body->>'account_id','')::bigint;
        v_currency:=v_body->>'currency';
        return moneytrack.receipt_projection_accounting_update_v1(v_actor,p_space_id,v_id,v_account_id,v_currency);
    end if;

    if v_method='PATCH' and v_path='api/v1/receipt-item/category' then
        v_id:=nullif(v_body->>'receipt_item_id','')::bigint;
        v_category_id:=nullif(v_body->>'category_id','')::bigint;
        return moneytrack.receipt_item_projection_set_category_by_item_v1(v_actor,p_space_id,v_id,v_category_id);
    end if;

    -- UX-022 transaction list / explorer -----------------------------------
    if v_method='GET' and v_path='api/v1/transactions' then
        v_account_id:=nullif(v_query->>'account_id','')::bigint;
        v_date_from:=nullif(v_query->>'date_from','')::date;
        v_date_to:=nullif(v_query->>'date_to','')::date;
        v_accounts:=moneytrack.spc001_parse_bigint_csv_v1(v_query->>'selected_account_ids',true);
        v_income:=moneytrack.spc001_parse_bigint_csv_v1(v_query->>'income_category_ids',true);
        v_expense:=moneytrack.spc001_parse_bigint_csv_v1(v_query->>'expense_category_ids',true);
        select to_jsonb(t) into v_result
          from moneytrack.api_transactions_space_read_model_v1(
            v_actor,p_space_id,v_account_id,v_date_from,v_date_to,
            coalesce((v_query->>'include_descendants')::boolean,true),v_accounts,v_income,v_expense
          ) t;
        return v_result;
    end if;

    if v_method='GET' and v_path='api/v1/accounts-explorer-summary' then
        v_date_from:=nullif(v_query->>'date_from','')::date;
        v_date_to:=nullif(v_query->>'date_to','')::date;
        v_accounts:=moneytrack.spc001_parse_bigint_csv_v1(v_query->>'selected_account_ids',false);
        v_income:=moneytrack.spc001_parse_bigint_csv_v1(v_query->>'income_category_ids',true);
        v_expense:=moneytrack.spc001_parse_bigint_csv_v1(v_query->>'expense_category_ids',true);
        select to_jsonb(s) into v_result
          from moneytrack.api_accounts_explorer_summary_space_v1(
            v_actor,p_space_id,v_accounts,v_income,v_expense,v_date_from,v_date_to,v_date_to
          ) s;
        return v_result;
    end if;

    -- USER_SPACE_PREFERENCE presets ----------------------------------------
    if v_path='api/v1/filter-presets' then
        if v_method='GET' then
            select jsonb_build_object('presets',p.presets) into v_result
              from moneytrack.filter_presets_space_read_v1(v_actor,p_space_id) p;
            return v_result;
        elsif v_method='POST' then
            v_accounts:=moneytrack.spc001_json_bigint_array_v1(v_body->'account_ids',false);
            v_income:=moneytrack.spc001_json_bigint_array_v1(v_body->'income_category_ids',false);
            v_expense:=moneytrack.spc001_json_bigint_array_v1(v_body->'expense_category_ids',false);
            select jsonb_build_object('preset',p.preset) into v_result
              from moneytrack.filter_preset_create_space_v1(v_actor,p_space_id,v_body->>'name',v_accounts,v_income,v_expense) p;
            return v_result;
        elsif v_method='PATCH' then
            v_id:=nullif(v_body->>'id','')::bigint;
            select jsonb_build_object('preset',p.preset) into v_result
              from moneytrack.filter_preset_rename_space_v1(v_actor,p_space_id,v_id,v_body->>'name') p;
            return v_result;
        elsif v_method='DELETE' then
            v_id:=nullif(v_query->>'id','')::bigint;
            select to_jsonb(p) into v_result
              from moneytrack.filter_preset_delete_space_v1(v_actor,p_space_id,v_id) p;
            return v_result;
        end if;
    end if;

    raise exception 'SPC001_API_METHOD_NOT_ALLOWED: % %',v_method,v_path using errcode='42501';
end;
$function$;

comment on function moneytrack.spc001_financial_api_dispatch_v1(bigint,bigint,text,text,jsonb,jsonb)
is 'SPC-001 fail-closed Class B financial API dispatcher. Verified Telegram identity resolves actor; requested Space is authorized by active membership on every request; unknown route/method is rejected.';

commit;
