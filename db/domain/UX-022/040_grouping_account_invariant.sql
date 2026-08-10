-- MoneyTrack — UX-022R3 — grouping account invariant
-- Parent/grouping accounts are structural only and cannot own direct operations.

begin;

create or replace function moneytrack.ux022_account_has_direct_operations_v1(
    p_user_id bigint,
    p_account_id bigint
)
returns boolean
language sql
stable
as $function$
    select exists (
        select 1
        from moneytrack.transactions t
        where t.user_id = p_user_id
          and t.account_id = p_account_id
    ) or exists (
        select 1
        from moneytrack.transfers tr
        where tr.user_id = p_user_id
          and (tr.from_account_id = p_account_id or tr.to_account_id = p_account_id)
    );
$function$;

create or replace function moneytrack.ux022_account_has_active_children_v1(
    p_user_id bigint,
    p_account_id bigint
)
returns boolean
language sql
stable
as $function$
    select exists (
        select 1
        from moneytrack.accounts child
        where child.user_id = p_user_id
          and child.parent_id = p_account_id
          and coalesce(child.is_active, true) = true
    );
$function$;

-- Fail closed instead of silently hiding legacy direct operations under a parent.
do $block$
declare
    v_count bigint;
begin
    select count(*)
      into v_count
      from moneytrack.accounts a
     where coalesce(a.is_active, true) = true
       and moneytrack.ux022_account_has_active_children_v1(a.user_id, a.id)
       and moneytrack.ux022_account_has_direct_operations_v1(a.user_id, a.id);

    if v_count > 0 then
        raise exception 'ACCOUNT_GROUPING_LEGACY_VIOLATION: % parent account(s) have direct operations', v_count
            using errcode = '23514';
    end if;
end;
$block$;

create or replace function moneytrack.ux022_guard_parent_account_v1()
returns trigger
language plpgsql
as $function$
declare
    v_parent_user_id bigint;
begin
    if new.parent_id is null then
        return new;
    end if;

    select a.user_id
      into v_parent_user_id
      from moneytrack.accounts a
     where a.id = new.parent_id
       and coalesce(a.is_active, true) = true;

    if v_parent_user_id is null or v_parent_user_id <> new.user_id then
        raise exception 'TARGET_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
    end if;

    if moneytrack.ux022_account_has_direct_operations_v1(new.user_id, new.parent_id) then
        raise exception 'ACCOUNT_PARENT_HAS_OPERATIONS' using errcode = '23514';
    end if;

    return new;
end;
$function$;

create or replace function moneytrack.ux022_guard_transaction_postable_account_v1()
returns trigger
language plpgsql
as $function$
begin
    if moneytrack.ux022_account_has_active_children_v1(new.user_id, new.account_id) then
        raise exception 'ACCOUNT_GROUP_NOT_POSTABLE' using errcode = '23514';
    end if;
    return new;
end;
$function$;

create or replace function moneytrack.ux022_guard_transfer_postable_accounts_v1()
returns trigger
language plpgsql
as $function$
begin
    if moneytrack.ux022_account_has_active_children_v1(new.user_id, new.from_account_id)
       or moneytrack.ux022_account_has_active_children_v1(new.user_id, new.to_account_id)
    then
        raise exception 'ACCOUNT_GROUP_NOT_POSTABLE' using errcode = '23514';
    end if;
    return new;
end;
$function$;

drop trigger if exists ux022_accounts_parent_group_guard on moneytrack.accounts;
create trigger ux022_accounts_parent_group_guard
before insert or update of parent_id on moneytrack.accounts
for each row execute function moneytrack.ux022_guard_parent_account_v1();

drop trigger if exists ux022_transactions_group_posting_guard on moneytrack.transactions;
create trigger ux022_transactions_group_posting_guard
before insert or update of account_id, user_id on moneytrack.transactions
for each row execute function moneytrack.ux022_guard_transaction_postable_account_v1();

drop trigger if exists ux022_transfers_group_posting_guard on moneytrack.transfers;
create trigger ux022_transfers_group_posting_guard
before insert or update of from_account_id, to_account_id, user_id on moneytrack.transfers
for each row execute function moneytrack.ux022_guard_transfer_postable_accounts_v1();

commit;
