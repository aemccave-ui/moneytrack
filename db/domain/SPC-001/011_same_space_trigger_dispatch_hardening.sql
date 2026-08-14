-- MoneyTrack — SPC-001A — same-Space trigger dynamic-record hardening
--
-- PostgreSQL trigger NEW is a dynamic record. Referencing NEW.some_field in the
-- same boolean condition that checks TG_TABLE_NAME is unsafe: PL/pgSQL can try
-- to resolve the field for a row type that does not contain it before ordinary
-- boolean short-circuiting can protect the access. Dispatch by table first, then
-- inspect only fields that are known to exist on that table.

begin;

create or replace function moneytrack.spc001_assert_same_space_row_v1()
returns trigger
language plpgsql
as $function$
declare
    v_ref_space bigint;
    v_receipt_space bigint;
begin
    -- These finance tables all have user_id + space_id. Keep the global/template
    -- invariant separate from table-specific reference checks below.
    if tg_table_name in (
        'accounts','transactions','transfers','receipts',
        'category_catalog','product_catalog','budget_rules'
    ) then
        if new.user_id = 0 then
            if new.space_id is not null then
                raise exception 'SPC001_GLOBAL_TEMPLATE_CANNOT_HAVE_SPACE' using errcode = '23514';
            end if;
            return new;
        end if;
        if new.space_id is null then
            raise exception 'SPC001_SPACE_REQUIRED' using errcode = '23514';
        end if;
    end if;

    if tg_table_name = 'accounts' then
        if new.parent_id is not null then
            select a.space_id into v_ref_space
            from moneytrack.accounts a
            where a.id = new.parent_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_ACCOUNT_PARENT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    elsif tg_table_name = 'transactions' then
        select a.space_id into v_ref_space
        from moneytrack.accounts a
        where a.id = new.account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_TRANSACTION_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;

        if new.category_id is not null then
            select c.space_id into v_ref_space
            from moneytrack.category_catalog c
            where c.id = new.category_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_TRANSACTION_CATEGORY_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    elsif tg_table_name = 'transfers' then
        select a.space_id into v_ref_space
        from moneytrack.accounts a
        where a.id = new.from_account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_TRANSFER_FROM_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;

        select a.space_id into v_ref_space
        from moneytrack.accounts a
        where a.id = new.to_account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_TRANSFER_TO_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;

    elsif tg_table_name = 'receipts' then
        if new.transaction_id is not null then
            select t.space_id into v_ref_space
            from moneytrack.transactions t
            where t.id = new.transaction_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_RECEIPT_TRANSACTION_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    elsif tg_table_name = 'category_catalog' then
        -- No category-local FK needs checking here. user_id/space_id invariants
        -- were already enforced by the shared ownership block above.
        null;

    elsif tg_table_name = 'product_catalog' then
        if new.category_id is not null then
            select c.space_id into v_ref_space
            from moneytrack.category_catalog c
            where c.id = new.category_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_PRODUCT_CATEGORY_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    elsif tg_table_name = 'budget_rules' then
        if new.category_id is not null then
            select c.space_id into v_ref_space
            from moneytrack.category_catalog c
            where c.id = new.category_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_BUDGET_CATEGORY_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    elsif tg_table_name = 'space_default_accounts' then
        select a.space_id into v_ref_space
        from moneytrack.accounts a
        where a.id = new.account_id;
        if v_ref_space is distinct from new.space_id then
            raise exception 'SPC001_DEFAULT_ACCOUNT_CROSS_SPACE' using errcode = '23514';
        end if;

    elsif tg_table_name = 'space_financial_settings' then
        if new.default_expense_account_id is not null then
            select a.space_id into v_ref_space
            from moneytrack.accounts a
            where a.id = new.default_expense_account_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_DEFAULT_EXPENSE_ACCOUNT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

        if new.default_income_account_id is not null then
            select a.space_id into v_ref_space
            from moneytrack.accounts a
            where a.id = new.default_income_account_id;
            if v_ref_space is distinct from new.space_id then
                raise exception 'SPC001_DEFAULT_INCOME_ACCOUNT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    elsif tg_table_name = 'receipt_items' then
        select r.space_id into v_receipt_space
        from moneytrack.receipts r
        where r.id = new.receipt_id;

        if new.category_id is not null then
            select c.space_id into v_ref_space
            from moneytrack.category_catalog c
            where c.id = new.category_id;
            if v_ref_space is distinct from v_receipt_space then
                raise exception 'SPC001_RECEIPT_ITEM_CATEGORY_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

        if new.product_id is not null then
            select p.space_id into v_ref_space
            from moneytrack.product_catalog p
            where p.id = new.product_id;
            if v_ref_space is distinct from v_receipt_space then
                raise exception 'SPC001_RECEIPT_ITEM_PRODUCT_CROSS_SPACE' using errcode = '23514';
            end if;
        end if;

    else
        raise exception 'SPC001_UNSUPPORTED_SAME_SPACE_TRIGGER_TABLE: %', tg_table_name
            using errcode = '23514';
    end if;

    return new;
end;
$function$;

comment on function moneytrack.spc001_assert_same_space_row_v1()
is 'SPC-001 same-Space relational invariant. TG_TABLE_NAME is dispatched before reading table-specific NEW fields so dynamic trigger records never access absent columns.';

commit;
