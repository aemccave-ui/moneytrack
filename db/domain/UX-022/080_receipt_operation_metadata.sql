-- MoneyTrack — UX-022R3 — Receipt operation metadata finalization
-- Source-only until an explicit backend/runtime deploy is authorized.
--
-- Rules:
--   * receipt clock time wins when the parser supplies it;
--   * when the receipt has only a date, keep that date and use the Telegram
--     ingress clock time as fallback rather than midnight;
--   * a receipt transaction gets a category only when all classified receipt
--     items resolve to one unique category; mixed receipts stay uncategorized.

begin;

create or replace function moneytrack.receipt_finalize_transaction_metadata_v1(
    p_user_id bigint,
    p_receipt_id bigint,
    p_receipt_time_text text,
    p_message_epoch bigint
)
returns table (
    transaction_id bigint,
    transaction_date timestamptz,
    category_id bigint,
    category_status text,
    time_status text
)
language plpgsql
volatile
as $function$
declare
    v_transaction_id bigint;
    v_receipt_date date;
    v_time_text text := nullif(btrim(p_receipt_time_text), '');
    v_fallback_at timestamptz := case when p_message_epoch is null then current_timestamp else to_timestamp(p_message_epoch) end;
    v_effective_at timestamptz;
    v_category_count integer := 0;
    v_category_id bigint;
    v_category_status text;
    v_time_status text;
begin
    select r.transaction_id, r.receipt_date
      into v_transaction_id, v_receipt_date
      from moneytrack.receipts r
     where r.id = p_receipt_id
       and r.user_id = p_user_id
     limit 1;

    if v_transaction_id is null then
        raise exception 'RECEIPT_TRANSACTION_NOT_FOUND' using errcode = 'P0002';
    end if;

    if v_receipt_date is not null and v_time_text ~ '^([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?$' then
        begin
            v_effective_at := (
                v_receipt_date::text || ' ' ||
                case when length(v_time_text) = 5 then v_time_text || ':00' else v_time_text end
            )::timestamp::timestamptz;
            v_time_status := 'receipt_time';
        exception when others then
            v_effective_at := null;
        end;
    end if;

    if v_effective_at is null and v_receipt_date is not null then
        v_effective_at := (
            v_receipt_date::text || ' ' || to_char(v_fallback_at, 'HH24:MI:SS')
        )::timestamp::timestamptz;
        v_time_status := 'receipt_date_ingress_time';
    end if;

    if v_effective_at is null then
        v_effective_at := v_fallback_at;
        v_time_status := 'ingress_time';
    end if;

    select count(distinct ri.category_id)::integer, min(ri.category_id)
      into v_category_count, v_category_id
      from moneytrack.receipt_items ri
     where ri.receipt_id = p_receipt_id
       and ri.category_id is not null;

    if v_category_count = 1 then
        v_category_status := 'single_item_category';
    elsif v_category_count > 1 then
        v_category_id := null;
        v_category_status := 'mixed_categories';
    else
        v_category_id := null;
        v_category_status := 'uncategorized';
    end if;

    update moneytrack.transactions t
       set transaction_date = v_effective_at,
           category_id = v_category_id
     where t.id = v_transaction_id
       and t.user_id = p_user_id;

    if not found then
        raise exception 'TRANSACTION_NOT_FOUND_OR_NOT_OWNED' using errcode = 'P0002';
    end if;

    return query
    select v_transaction_id, v_effective_at, v_category_id, v_category_status, v_time_status;
end;
$function$;

comment on function moneytrack.receipt_finalize_transaction_metadata_v1(bigint,bigint,text,bigint)
is 'UX-022R3 receipt transaction metadata: receipt time when available, ingress-time fallback, and conservative single-category projection from receipt items.';

commit;
