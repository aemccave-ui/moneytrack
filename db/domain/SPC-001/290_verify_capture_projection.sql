-- MoneyTrack — SPC-001C — multi-Space / receipt projection verifier
--
-- Run after SPC-001A + B + 210 + 211 in a controlled dry-run database.
-- Synthetic state is transaction-local and always rolled back.

begin;

do $capture_projection_fixture$
declare
    v_a record;
    v_b record;
    v_family bigint;
    v_p_account bigint;
    v_f_account bigint;
    v_p_cat bigint;
    v_f_cat bigint;
    v_f_cat2 bigint;
    v_currency text;
    v_capture record;
    v_family_tx bigint;
    v_personal_tx bigint;
    v_visible bigint;
    v_bad boolean;
    v_before_cat bigint;
    v_after_cat bigint;
    v_receipt_capture record;
    v_receipt_id bigint;
    v_item_id bigint;
    v_receipt_family_tx bigint;
    v_p_read jsonb;
    v_f_read jsonb;
    v_atomic_capture record;
    v_count bigint;
begin
    select * into v_a
      from moneytrack.spc001_user_bootstrap_v1(-930000001,'spc_a_c','SPC A C','en');
    select * into v_b
      from moneytrack.spc001_user_bootstrap_v1(-930000002,'spc_b_c','SPC B C','en');

    select s.space_id into v_family
      from moneytrack.space_create_v1(v_a.user_id,'SPC Capture Family') s;

    -- B joins Family but never joins A's Personal Space.
    insert into moneytrack.workspace_members(
        workspace_id,user_id,role,is_active,created_at,joined_at,invited_by_user_id,removed_at
    ) values (
        v_family,v_b.user_id,'member',true,now(),now(),v_a.user_id,null
    ) on conflict (workspace_id,user_id) do update
      set role='member',is_active=true,joined_at=now(),removed_at=null;

    select upper(s.base_currency) into v_currency
      from moneytrack.space_financial_settings s where s.space_id=v_a.space_id;

    -- Select equivalent template-derived, base-currency, postable leaf accounts
    -- in both Spaces. This verifier exercises tenancy/projection semantics, not
    -- unrelated FX availability or the UX-022 grouping-account rejection path.
    select pa.id,fa.id into v_p_account,v_f_account
      from moneytrack.accounts pa
      join moneytrack.accounts fa on fa.code=pa.code
     where pa.space_id=v_a.space_id
       and fa.space_id=v_family
       and coalesce(pa.is_active,true)=true
       and coalesce(fa.is_active,true)=true
       and upper(pa.currency_code)=v_currency
       and upper(fa.currency_code)=v_currency
       and not moneytrack.ux022_account_has_active_children_v1(pa.user_id,pa.id)
       and not moneytrack.ux022_account_has_active_children_v1(fa.user_id,fa.id)
     order by pa.id limit 1;

    select pc.id,fc.id into v_p_cat,v_f_cat
      from moneytrack.category_catalog pc
      join moneytrack.category_catalog fc on fc.code=pc.code
     where pc.space_id=v_a.space_id
       and fc.space_id=v_family
       and coalesce(pc.is_active,true)=true
       and coalesce(fc.is_active,true)=true
     order by pc.id limit 1;

    select fc.id into v_f_cat2
      from moneytrack.category_catalog fc
     where fc.space_id=v_family
       and fc.id<>v_f_cat
       and coalesce(fc.is_active,true)=true
     order by fc.id limit 1;

    if v_p_account is null or v_f_account is null or v_p_cat is null or v_f_cat is null or v_f_cat2 is null then
        raise exception 'SPC001_CAPTURE_FIXTURE_REFERENCES_MISSING';
    end if;

    -- One real-world text capture -> Personal first projection.
    select * into v_capture
      from moneytrack.capture_create_projection_v1(
          v_a.user_id,v_a.space_id,'text','fixture-text-1',
          v_p_account,'expense',25,v_currency,'shared event',now(),v_p_cat,
          jsonb_build_object('fixture',true)
      );
    v_personal_tx:=v_capture.transaction_id;

    -- Project same event to Family using Family-local refs.
    select p.transaction_id into v_family_tx
      from moneytrack.capture_project_multi_v1(
          v_a.user_id,v_capture.capture_event_id,
          jsonb_build_array(jsonb_build_object(
              'space_id',v_family,
              'account_id',v_f_account,
              'category_id',v_f_cat
          ))
      ) p;

    if v_family_tx is null or v_family_tx=v_personal_tx then
        raise exception 'SPC001_MULTI_SPACE_SECOND_PROJECTION_MISSING';
    end if;

    -- A sees Personal + Family; B sees Family only. No hidden total exists in
    -- the linkage read model, so B's result cardinality is exactly one.
    select count(*) into v_visible
      from moneytrack.capture_accessible_projections_v1(v_a.user_id,v_capture.capture_event_id);
    if v_visible<>2 then raise exception 'SPC001_OWNER_VISIBLE_PROJECTION_COUNT: %',v_visible; end if;

    select count(*) into v_visible
      from moneytrack.capture_accessible_projections_v1(v_b.user_id,v_capture.capture_event_id) x
     where x.space_id=v_family;
    if v_visible<>1 then raise exception 'SPC001_MEMBER_VISIBLE_FAMILY_COUNT: %',v_visible; end if;

    if exists (
        select 1 from moneytrack.capture_accessible_projections_v1(v_b.user_id,v_capture.capture_event_id) x
        where x.space_id=v_a.space_id or x.transaction_id=v_personal_tx
    ) then raise exception 'SPC001_HIDDEN_PERSONAL_LINKAGE_LEAKED'; end if;

    -- Family edit is financially independent and original author remains A.
    select t.category_id into v_before_cat from moneytrack.transactions t where t.id=v_personal_tx;
    perform moneytrack.finance_update_transaction_space_v1(
        v_b.user_id,v_family,v_family_tx,v_f_account,'expense',25,v_currency,
        'family edited by B',
        (select t.transaction_date from moneytrack.transactions t where t.id=v_family_tx),
        v_f_cat2
    );
    select t.category_id into v_after_cat from moneytrack.transactions t where t.id=v_personal_tx;
    if v_after_cat is distinct from v_before_cat then
        raise exception 'SPC001_FAMILY_EDIT_MUTATED_PERSONAL';
    end if;
    if (select t.created_by_user_id from moneytrack.transactions t where t.id=v_family_tx) is distinct from v_a.user_id then
        raise exception 'SPC001_PROJECTION_ORIGINAL_AUTHOR_CHANGED';
    end if;

    -- B may delete ordinary shared financial CRUD; Personal projection survives.
    perform moneytrack.finance_delete_transaction_space_v1(v_b.user_id,v_family,v_family_tx);
    if not exists (select 1 from moneytrack.transactions t where t.id=v_personal_tx) then
        raise exception 'SPC001_FAMILY_DELETE_REMOVED_PERSONAL';
    end if;

    -- -----------------------------------------------------------------------
    -- Receipt source: immutable parser facts shared, classification per Space.
    -- -----------------------------------------------------------------------
    select * into v_receipt_capture
      from moneytrack.capture_create_projection_v1(
          v_a.user_id,v_a.space_id,'photo_receipt','fixture-receipt-1',
          v_p_account,'expense',31,v_currency,'Receipt merchant',now(),v_p_cat,
          jsonb_build_object('parser','fixture')
      );

    insert into moneytrack.capture_receipts(
        capture_event_id,merchant,recognized_at,total_amount,currency,
        telegram_file_id,receipt_fingerprint,raw_ai_json,created_at
    ) values (
        v_receipt_capture.capture_event_id,'Fixture Merchant',now(),31,v_currency,
        'fixture-file','fixture-fingerprint',jsonb_build_object('immutable',true),now()
    ) returning id into v_receipt_id;

    insert into moneytrack.capture_receipt_items(
        capture_receipt_id,item_name_original,item_language,quantity,unit_price,amount,created_at
    ) values (
        v_receipt_id,'Fixture Item','en',1,31,31,now()
    ) returning id into v_item_id;

    select p.transaction_id into v_receipt_family_tx
      from moneytrack.capture_project_multi_v1(
          v_a.user_id,v_receipt_capture.capture_event_id,
          jsonb_build_array(jsonb_build_object(
              'space_id',v_family,
              'account_id',v_f_account,
              'category_id',v_f_cat
          ))
      ) p;

    perform moneytrack.receipt_projection_set_classification_v1(
        v_a.user_id,v_a.space_id,v_receipt_capture.transaction_id,v_item_id,v_p_cat,null
    );
    perform moneytrack.receipt_projection_set_classification_v1(
        v_b.user_id,v_family,v_receipt_family_tx,v_item_id,v_f_cat2,null
    );

    v_p_read:=moneytrack.receipt_projection_read_v1(
        v_a.user_id,v_a.space_id,v_receipt_capture.transaction_id
    );
    v_f_read:=moneytrack.receipt_projection_read_v1(
        v_b.user_id,v_family,v_receipt_family_tx
    );

    if v_p_read->>'merchant' is distinct from v_f_read->>'merchant'
       or v_p_read->>'total_amount' is distinct from v_f_read->>'total_amount'
       or v_p_read->>'currency' is distinct from v_f_read->>'currency'
    then raise exception 'SPC001_RECEIPT_IMMUTABLE_SOURCE_DIVERGED'; end if;

    if (v_p_read->'items'->0->>'category_id')::bigint is distinct from v_p_cat then
        raise exception 'SPC001_PERSONAL_RECEIPT_CLASSIFICATION_WRONG';
    end if;
    if (v_f_read->'items'->0->>'category_id')::bigint is distinct from v_f_cat2 then
        raise exception 'SPC001_FAMILY_RECEIPT_CLASSIFICATION_WRONG';
    end if;

    -- Foreign-Space classification fails closed.
    v_bad:=false;
    begin
        perform moneytrack.receipt_projection_set_classification_v1(
            v_b.user_id,v_family,v_receipt_family_tx,v_item_id,v_p_cat,null
        );
    exception when others then
        if sqlerrm like '%CATEGORY_NOT_FOUND_IN_SPACE%'
           or sqlerrm like '%CROSS_SPACE%' then v_bad:=true; else raise; end if;
    end;
    if not v_bad then raise exception 'SPC001_RECEIPT_FOREIGN_CATEGORY_ACCEPTED'; end if;

    -- Family-only member cannot read Personal receipt projection.
    v_bad:=false;
    begin
        perform moneytrack.receipt_projection_read_v1(
            v_b.user_id,v_a.space_id,v_receipt_capture.transaction_id
        );
    exception when others then
        if sqlerrm like '%SPACE_NOT_FOUND_OR_NOT_MEMBER%' then v_bad:=true; else raise; end if;
    end;
    if not v_bad then raise exception 'SPC001_RECEIPT_PERSONAL_PRIVACY_FAILED'; end if;

    -- Deleting Family receipt projection leaves Personal + source intact.
    perform moneytrack.finance_delete_transaction_space_v1(v_b.user_id,v_family,v_receipt_family_tx);
    if moneytrack.receipt_projection_read_v1(
        v_a.user_id,v_a.space_id,v_receipt_capture.transaction_id
    ) is null then raise exception 'SPC001_RECEIPT_PERSONAL_DID_NOT_SURVIVE_DELETE'; end if;

    -- -----------------------------------------------------------------------
    -- Atomicity: target 1 is valid Family, target 2 is invalid. Exception must
    -- roll the first projection back; partial success is forbidden.
    -- -----------------------------------------------------------------------
    select * into v_atomic_capture
      from moneytrack.capture_create_projection_v1(
          v_a.user_id,v_a.space_id,'manual','fixture-atomic-1',
          v_p_account,'expense',7,v_currency,'atomic test',now(),v_p_cat,'{}'::jsonb
      );

    v_bad:=false;
    begin
        perform moneytrack.capture_project_multi_v1(
            v_a.user_id,v_atomic_capture.capture_event_id,
            jsonb_build_array(
                jsonb_build_object('space_id',v_family,'account_id',v_f_account,'category_id',v_f_cat),
                jsonb_build_object('space_id',v_family,'account_id',v_p_account,'category_id',v_f_cat)
            )
        );
    exception when others then
        if sqlerrm like '%CAPTURE_EVENT_ALREADY_PROJECTED_TO_SPACE%'
           or sqlerrm like '%ACCOUNT_NOT_FOUND_IN_SPACE%' then v_bad:=true; else raise; end if;
    end;
    if not v_bad then raise exception 'SPC001_MULTI_SPACE_PARTIAL_FAILURE_NOT_RAISED'; end if;

    select count(*) into v_count
      from moneytrack.transactions t
     where t.capture_event_id=v_atomic_capture.capture_event_id and t.space_id=v_family;
    if v_count<>0 then raise exception 'SPC001_MULTI_SPACE_PARTIAL_SUCCESS_LEAKED'; end if;

    raise notice 'CAPTURE_EVENT_MULTI_PROJECTION=PASS';
    raise notice 'MULTI_SPACE_POSTINGS_INDEPENDENT=PASS';
    raise notice 'MULTI_SPACE_ATOMICITY=PASS';
    raise notice 'HIDDEN_SPACE_LINKAGE_NOT_LEAKED=PASS';
    raise notice 'RECEIPT_SOURCE_SHARED_IMMUTABLE=PASS';
    raise notice 'RECEIPT_CLASSIFICATION_SPACE_SPECIFIC=PASS';
end;
$capture_projection_fixture$;

rollback;
