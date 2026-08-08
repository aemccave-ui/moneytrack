-- MoneyTrack — BE-DOM-001 — rollback
--
-- Use only when the extracted PostgreSQL entry points themselves must be
-- removed. Normal runtime rollback should first restore the legacy n8n queries
-- and keep these functions installed for diagnosis.

begin;

drop function if exists moneytrack.finance_dashboard_read_model_v1(bigint, date);
drop function if exists moneytrack.finance_accounts_read_model_v1(bigint);
drop function if exists moneytrack.finance_fx_convert_usd_bridge_v1(numeric, text, text, date);

commit;
