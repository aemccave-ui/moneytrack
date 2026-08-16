-- MoneyTrack — SPC-001C — receipt projection readback wrappers
-- SOURCE ONLY until controlled runtime apply.

begin;

create or replace function moneytrack.receipt_projection_classified_item_read_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_capture_receipt_id bigint
)
returns table(
    id bigint,
    receipt_id bigint,
    item_name_original text,
    category_id bigint,
    product_id bigint
)
language plpgsql
stable
as $function$
declare v_transaction_id bigint;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    select t.id into v_transaction_id
      from moneytrack.capture_receipts cr
      join moneytrack.transactions t
        on t.capture_event_id=cr.capture_event_id
       and t.space_id=p_space_id
     where cr.id=p_capture_receipt_id
     limit 1;

    if v_transaction_id is null then
        raise exception 'RECEIPT_PROJECTION_NOT_FOUND_IN_SPACE' using errcode='P0002';
    end if;

    return query
    select
        cri.id,
        p_capture_receipt_id,
        cri.item_name_original,
        ric.category_id,
        ric.product_id
    from moneytrack.capture_receipt_items cri
    join moneytrack.capture_receipts cr on cr.id=cri.capture_receipt_id
    join moneytrack.receipt_item_projection_classification ric
      on ric.transaction_id=v_transaction_id
     and ric.capture_receipt_item_id=cri.id
    where cr.id=p_capture_receipt_id
      and ric.category_id is not null
    order by cri.id
    limit 1;
end;
$function$;

comment on function moneytrack.receipt_projection_classified_item_read_v1(bigint,bigint,bigint)
is 'SPC-001 one-row photo-workflow readback. Membership and projection scoping stay in backend; n8n receives no cross-Space join capability.';

commit;
