-- MoneyTrack SPC-001 extended finance correction.
-- Apply after 030_space_extended_finance_domain.sql.

begin;

create or replace function moneytrack.account_move_operations_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_source_account_id bigint,
    p_target_account_id bigint
)
returns table(operation_count bigint,transfer_count bigint,status text)
language plpgsql
volatile
as $function$
declare
    v_preview record;
    v_ops bigint := 0;
    v_from_transfers bigint := 0;
    v_to_transfers bigint := 0;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select * into v_preview
      from moneytrack.account_move_operations_preview_space_v1(
          p_actor_user_id,p_space_id,p_source_account_id,p_target_account_id
      );

    if v_preview.opening_balance_conflict then
        raise exception 'OPENING_BALANCE_CONFLICT' using errcode='23505';
    end if;
    if v_preview.collapsing_transfer_count > 0 then
        raise exception 'COLLAPSING_TRANSFER_CONFLICT' using errcode='23505';
    end if;

    update moneytrack.transactions
       set account_id=p_target_account_id,
           updated_by_user_id=p_actor_user_id
     where space_id=p_space_id and account_id=p_source_account_id;
    get diagnostics v_ops = row_count;

    update moneytrack.transfers
       set from_account_id=p_target_account_id,
           updated_by_user_id=p_actor_user_id
     where space_id=p_space_id and from_account_id=p_source_account_id;
    get diagnostics v_from_transfers = row_count;

    update moneytrack.transfers
       set to_account_id=p_target_account_id,
           updated_by_user_id=p_actor_user_id
     where space_id=p_space_id and to_account_id=p_source_account_id;
    get diagnostics v_to_transfers = row_count;

    return query select v_ops,v_from_transfers+v_to_transfers,'moved'::text;
end;
$function$;

commit;
