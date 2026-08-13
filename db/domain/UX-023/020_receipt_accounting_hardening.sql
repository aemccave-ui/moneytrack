-- MoneyTrack — UX-023 — remove the superseded currency-only receipt mutation.
-- Receipt accounting corrections must provide account + currency atomically.

begin;

drop function if exists moneytrack.receipt_set_currency_v1(bigint,bigint,text);

commit;
