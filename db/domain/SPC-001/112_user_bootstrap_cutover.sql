-- MoneyTrack — SPC-001B — canonical user-bootstrap compatibility cutover
-- Apply after 014_space_bootstrap.sql and 110_space_lifecycle.sql.
--
-- SEC-001 Class A status deliberately calls moneytrack.user_bootstrap_v1 before
-- the protected financial application mounts. Preserve that accepted signature,
-- but delegate financial initialization to the SPC Space-owned bootstrap so a
-- first-time/invited Telegram user never creates legacy user-owned finance rows.

begin;

create or replace function moneytrack.user_bootstrap_v1(
    p_telegram_user_id bigint,
    p_username text,
    p_first_name text,
    p_telegram_language_code text
)
returns table (
    user_id bigint,
    telegram_user_id bigint,
    language_code text,
    base_currency text,
    report_currency text,
    workspace_id bigint,
    workspace_role text,
    default_expense_account_id bigint,
    default_income_account_id bigint
)
language plpgsql
volatile
as $function$
declare
    v_boot record;
begin
    select * into v_boot
      from moneytrack.spc001_user_bootstrap_v1(
          p_telegram_user_id,
          p_username,
          p_first_name,
          p_telegram_language_code
      );

    -- Bot capture routing is explicit and independent of last active MiniApp
    -- Space. For a first user it defaults to the validated current/Personal Space.
    update moneytrack.user_settings us
       set default_capture_space_id=coalesce(us.default_capture_space_id,v_boot.space_id),
           updated_at=now()
     where us.user_id=v_boot.user_id;

    perform moneytrack.assert_space_member_v1(v_boot.user_id,v_boot.space_id);
    perform moneytrack.assert_space_member_v1(
        v_boot.user_id,
        (select us.default_capture_space_id from moneytrack.user_settings us where us.user_id=v_boot.user_id)
    );

    return query
    select
        v_boot.user_id,
        v_boot.telegram_user_id,
        v_boot.language_code,
        v_boot.base_currency,
        v_boot.report_currency,
        v_boot.space_id,
        v_boot.workspace_role,
        v_boot.default_expense_account_id,
        v_boot.default_income_account_id;
end;
$function$;

comment on function moneytrack.user_bootstrap_v1(bigint,text,text,text)
is 'SPC-001 compatibility cutover for the canonical first-user bootstrap used by SEC-001. Same API signature; all financial initialization is Space-owned and default Bot capture is explicit.';

commit;
