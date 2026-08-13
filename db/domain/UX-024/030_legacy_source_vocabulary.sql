-- MoneyTrack — UX-024 — persisted legacy source vocabulary correction
--
-- Runtime forensic 2026-08-13 proved the historical transaction vocabulary is:
--   telegram_text, receipt, qa_autotest, NULL
-- and source_id is not populated / has no persisted ingress metadata relation.
--
-- Only exact persisted mappings are allowed here.
-- Unknown/QA/NULL rows stay unknown. Voice is never inferred from content,
-- description, timestamp or any other heuristic.

begin;

create or replace function moneytrack.operation_source_kind_v1(
    p_user_id bigint,
    p_transaction_id bigint
)
returns text
language sql
stable
as $function$
    select case
        -- Canonical persisted receipt relation is authoritative.
        when exists (
            select 1
            from moneytrack.receipts r
            where r.user_id = p_user_id
              and r.transaction_id = p_transaction_id
        ) then 'photo_receipt'::text

        -- Current + exact persisted legacy receipt vocabulary.
        when lower(coalesce(t.source_type, '')) in (
            'photo_receipt',
            'photo',
            'receipt'
        ) then 'photo_receipt'::text

        -- Current sourced-write vocabulary.
        when lower(coalesce(t.source_type, '')) = 'voice'
            then 'voice'::text

        -- Exact persisted legacy Text writer label.
        when lower(coalesce(t.source_type, '')) in (
            'text',
            'telegram_text'
        ) then 'text'::text

        when lower(coalesce(t.source_type, '')) in (
            'miniapp',
            'manual'
        ) then 'manual'::text

        -- qa_autotest and NULL have no proven end-user source semantics.
        else null::text
    end
    from moneytrack.transactions t
    where t.id = p_transaction_id
      and t.user_id = p_user_id;
$function$;

comment on function moneytrack.operation_source_kind_v1(bigint,bigint)
is 'UX-024 persisted operation source resolver. Exact legacy mappings: telegram_text -> text and receipt -> photo_receipt. Receipt relation is authoritative. NULL/qa_autotest remain unknown; no content/timestamp heuristics and no retroactive voice inference.';

commit;
