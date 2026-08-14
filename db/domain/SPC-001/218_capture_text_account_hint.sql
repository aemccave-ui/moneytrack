-- MoneyTrack — SPC-001C — Space-native text account hint inference
-- SOURCE ONLY until controlled runtime apply.
--
-- Preserves the accepted Text Processor convenience behavior: when the parser
-- did not provide account_hint, the raw command text may imply an account name.
-- The lookup is constrained to one authorized Space and never uses legacy
-- financial user_id ownership.

begin;

create or replace function moneytrack.capture_infer_account_hint_space_v1(
    p_actor_user_id bigint,
    p_space_id bigint,
    p_raw_text text,
    p_operation_type text,
    p_existing_account_hint text default null
)
returns text
language plpgsql
stable
as $function$
declare
    v_existing text:=nullif(btrim(p_existing_account_hint),'');
    v_operation text:=lower(nullif(btrim(p_operation_type),''));
    v_raw_norm text;
    v_account_hint text;
begin
    perform moneytrack.assert_space_member_v1(p_actor_user_id,p_space_id);

    if v_existing is not null then
        return v_existing;
    end if;

    if v_operation is null or v_operation not in ('expense','income','adjustment','openingbalance') then
        return null;
    end if;

    v_raw_norm:=lower(regexp_replace(coalesce(p_raw_text,''),'[^a-zA-Zа-яА-Я0-9]+','','g'));

    select a.name
      into v_account_hint
      from moneytrack.accounts a
     where a.space_id=p_space_id
       and coalesce(a.is_active,true)=true
       and v_raw_norm like '%' || lower(regexp_replace(a.name,'[^a-zA-Zа-яА-Я0-9]+','','g')) || '%'
     order by length(lower(regexp_replace(a.name,'[^a-zA-Zа-яА-Я0-9]+','','g'))) desc
     limit 1;

    return v_account_hint;
end;
$function$;

comment on function moneytrack.capture_infer_account_hint_space_v1(bigint,bigint,text,text,text)
is 'SPC-001 Text Processor account-hint inference. Active membership is asserted and account-name matching is restricted to the requested Space.';

commit;
