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

-- Persistent rollback journal for the one-time legacy data normalization.
create table if not exists moneytrack.ux022_grouping_transaction_migration_backup (
    transaction_id bigint primary key,
    user_id bigint not null,
    original_account_id bigint not null,
    target_account_id bigint not null,
    migrated_at timestamptz not null default now()
);

create table if not exists moneytrack.ux022_grouping_transfer_migration_backup (
    transfer_id bigint primary key,
    user_id bigint not null,
    original_from_account_id bigint not null,
    original_to_account_id bigint not null,
    target_account_id bigint not null,
    migrated_at timestamptz not null default now()
);

-- One-time legacy normalization.
-- If a legacy parent still owns direct history, move it to any safe active LEAF
-- child with the same currency. Selection is deterministic: sort_order, then id.
-- Candidates that would collapse a parent<->child transfer or duplicate an opening
-- balance are skipped. If no safe same-currency leaf exists, fail closed.
do $block$
declare
    v_parent record;
    v_target_id bigint;
begin
    for v_parent in
        select a.id, a.user_id, upper(a.currency_code) as currency_code, a.name
        from moneytrack.accounts a
        where coalesce(a.is_active, true) = true
          and moneytrack.ux022_account_has_active_children_v1(a.user_id, a.id)
          and moneytrack.ux022_account_has_direct_operations_v1(a.user_id, a.id)
        order by a.user_id, a.id
    loop
        select child.id
          into v_target_id
          from moneytrack.accounts child
         where child.user_id = v_parent.user_id
           and child.parent_id = v_parent.id
           and coalesce(child.is_active, true) = true
           and upper(child.currency_code) = v_parent.currency_code
           and not moneytrack.ux022_account_has_active_children_v1(child.user_id, child.id)
           and not exists (
                select 1
                from moneytrack.transfers tr
                where tr.user_id = v_parent.user_id
                  and (
                        (tr.from_account_id = v_parent.id and tr.to_account_id = child.id)
                     or (tr.to_account_id = v_parent.id and tr.from_account_id = child.id)
                  )
           )
           and not (
                exists (
                    select 1
                    from moneytrack.transactions src
                    where src.user_id = v_parent.user_id
                      and src.account_id = v_parent.id
                      and src.transaction_type = 'openingbalance'
                )
                and exists (
                    select 1
                    from moneytrack.transactions dst
                    where dst.user_id = v_parent.user_id
                      and dst.account_id = child.id
                      and dst.transaction_type = 'openingbalance'
                )
           )
         order by child.sort_order nulls last, child.id
         limit 1;

        if v_target_id is null then
            raise exception 'ACCOUNT_GROUPING_MIGRATION_SAFE_TARGET_MISSING: parent_id=% name=% currency=%',
                v_parent.id, v_parent.name, v_parent.currency_code
                using errcode = '23514';
        end if;

        insert into moneytrack.ux022_grouping_transaction_migration_backup(
            transaction_id, user_id, original_account_id, target_account_id
        )
        select t.id, t.user_id, t.account_id, v_target_id
        from moneytrack.transactions t
        where t.user_id = v_parent.user_id
          and t.account_id = v_parent.id
        on conflict (transaction_id) do nothing;

        insert into moneytrack.ux022_grouping_transfer_migration_backup(
            transfer_id, user_id, original_from_account_id, original_to_account_id, target_account_id
        )
        select tr.id, tr.user_id, tr.from_account_id, tr.to_account_id, v_target_id
        from moneytrack.transfers tr
        where tr.user_id = v_parent.user_id
          and (tr.from_account_id = v_parent.id or tr.to_account_id = v_parent.id)
        on conflict (transfer_id) do nothing;

        update moneytrack.transactions t
           set account_id = v_target_id
         where t.user_id = v_parent.user_id
           and t.account_id = v_parent.id;

        update moneytrack.transfers tr
           set from_account_id = v_target_id
         where tr.user_id = v_parent.user_id
           and tr.from_account_id = v_parent.id;

        update moneytrack.transfers tr
           set to_account_id = v_target_id
         where tr.user_id = v_parent.user_id
           and tr.to_account_id = v_parent.id;
    end loop;
end;
$block$;

-- After normalization there must be no active grouping account with direct history.
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
        raise exception 'ACCOUNT_GROUPING_LEGACY_VIOLATION: % parent account(s) still have direct operations', v_count
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
    if new.parent_id is null or not coalesce(new.is_active, true) then
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
before insert or update of parent_id, is_active on moneytrack.accounts
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
